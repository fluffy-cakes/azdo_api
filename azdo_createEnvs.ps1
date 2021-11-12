<#
    .SYNOPSIS
        Dynamically creates Azure DevOps "Environments" with security permissions, approvers and branch control.

    .DESCRIPTION
        The variable "$envList" is an object that sets the high level management groups and their settings which
        will be used to create each environment;
            approval       = enable approval checks
            branch_control = limit deployments only to ref/heads/main
            env_group      = which of the three environment groups the management group belows (nonprod, preprod, prod)

        The variable "$Global:groups" is an object for which each of the management groups cross references when
        setting security settings and approval checks. The "id" and "descriptor" are intentionally left blank so
        they can be populated with their correct values after a Graph API lookup of each group. Because the variable
        is iterated over in a loop, you cannot create new object keys, but you can update their current values.
        Meaning; if it did not have "descriptor" as a blank value, but you wanted to add descriptor to each sub-object
        after a lookup, it will fail on the second itteration with an error that the object has been updated outside of the loop.

        The variable "$defaultGroups" is a list of default groups that will be removed when updating the security
        settings. A new object variable "$Global:removeGroups" is created to populate each groups IDs via a
        Graph API lookup, which will then be used as a reference to remove default groups. Any groups in this object
        will be removed from the security settings of the new environment. However, the person who runs this script
        with their PAT will remain as Administrator.

        If parameter switch "Clear" is enabled, it will find only delete those Environments that are listed in
        $envList (_Build, _Delete, _Release) and leave other Environments alone as not to accidentally delete someone else's

        For each management group there will be the environments to create; {env}_Build, {env}_Delete and {env}_Release.
        The scrippt will create them if they don't exist, and also create the security settings, approvals and branch
        controls. All of which are set using "$envList" and "$Global:groups".

        For approvals, if a group is marked as an Adminstrator in "$Global:groups", that group will become the approval
        check for the Environment using regex string selection "Admins" on the group name. The "displayName" is compiled
        from the project name and the group name; [{project}]\{group name}. The ID is needed to attach the exact group,
        and the descriptor is used to display the groups image.

        When enabled, branch control is hardcoded to only authorise "refs/heads/main". It is unlikely that any other is
        needed at this time, but it can be adapted if need be.

    .PARAMETER Org
        The Azure DevOps organisation.

    .PARAMETER Project
        The Azure DevOps project inside the organisation.

    .PARAMETER Token
        Your pesonal access token used to authenticate with Azure DevOps.

    .PARAMETER Clear
        BEWARE!! Switch to DELETE listed environments.
#>

param(
    [Parameter(Mandatory=$true, Position=1)]
    [ValidateNotNullOrEmpty()]
    [string]$Org,

    [Parameter(Mandatory=$true, Position=2)]
    [ValidateNotNullOrEmpty()]
    [string]$Project,

    [Parameter(Mandatory=$true, Position=3)]
    [ValidateNotNullOrEmpty()]
    [string]$Token,

    [switch]$Clear
)




function Add-SomeGroups {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$Env,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvId,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$Type
    )


    # Remove base standard groups
    foreach($group in $Global:removeGroups.Keys) {
        $url  = "https://dev.azure.com/${Global:organization}/_apis/securityroles/scopes/distributedtask.environmentreferencerole/roleassignments/resources/${Global:projectId}_${EnvId}?api-version=5.0-preview.1"
        $body = "[`"$($Global:removeGroups["$group"])`"]"

        if($group -in $Global:groupList) {
            Write-Host "[-] REMOVE: $group" -ForegroundColor "Red"
            Invoke-RestMethod -Uri $url -Method 'PATCH' -Headers $headers -SkipCertificateCheck -Body $body | Out-Null
        }
    }


    # Add custom groups
    foreach($group in $Global:groups[$Type][$Env].Keys) {
        $url  = "https://dev.azure.com/${Global:organization}/_apis/securityroles/scopes/distributedtask.environmentreferencerole/roleassignments/resources/${Global:projectId}_${EnvId}?api-version=5.0-preview.1"
        $body = "[
        `n    {
        `n        `"userId`":   `"$($Global:groups[$Type][$Env][$group].id  )`",
        `n        `"roleName`": `"$($Global:groups[$Type][$Env][$group].role)`"
        `n    }
        `n]"

        if      ("[$Global:project]\$group" -notin $Global:groupList) {
            Write-Host "[+] ADDING: [$Global:project]\$group" -ForegroundColor "Green"
            Invoke-RestMethod -Uri $url -Method 'PUT' -Headers $headers -SkipCertificateCheck -Body $body | Out-Null
        }
        elseif  ( ($groupResponse.value | Where-Object { $_.identity.displayName -eq "[$Global:project]\$group" }).role.name -ne $Global:groups[$Type][$Env][$group].role) {
            Write-Host "[!] CHECK!: [$Global:project]\$group value did not match role" -ForegroundColor "Yellow"
            Invoke-RestMethod -Uri $url -Method 'PUT' -Headers $headers -SkipCertificateCheck -Body $body | Out-Null
        }
    }


    # Alert if other users/groups are in security settings
    # RE-List current groups in Environment. Sleep required for database refresh
    Start-Sleep -Seconds 1

    $url           = "https://dev.azure.com/${Global:organization}/_apis/securityroles/scopes/distributedtask.environmentreferencerole/roleassignments/resources/${Global:projectId}_${envSubId}"
    $groupResponse = Invoke-RestMethod -Uri $url -Method 'GET' -Headers $headers -SkipCertificateCheck
    $groupReList   = $groupResponse.value.identity.displayName

    $groupArray = @()
    foreach($thisGroup in $Global:groups[$Type][$Env].Keys) {
        $groupArray += $thisGroup
    }
    foreach($thing in $groupReList) {
        if($thing.Replace("[$Global:project]\", "") -notin $groupArray) {
            Write-Host "[!] CHECK!: $thing in security settings" -ForegroundColor "Yellow"
        }
    }
}




function Add-SomeApprovers {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvId,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$Env
    )


    # Find current approver list
    [array]$ApprovalGroups = @()
    $Global:groups[$Type][$Env].Keys | Select-String -Pattern "Admins" | Foreach-Object {
        $ApprovalGroups += "[$Global:project]\$($_)"
    }

    $url                = "https://dev.azure.com/${Global:organization}/${Global:project}/_environments/${EnvId}/checks?__rt=fps&__ver=2"
    $response           = Invoke-RestMethod -Uri $url -Method 'GET' -Headers $headers -SkipCertificateCheck
    $responseObject     = $response.fps.dataProviders.data.'ms.vss-pipelinechecks.checks-data-provider'.checkConfigurationDataList |
        Where-Object { $_.checkConfiguration.type.name -eq "Approval" }
    $approversIncorrect = $false


    # You can only have 1 approval group set, but multiple approvers can be in the group
    # If an approval set already exists, delete it and create the correct one
    if(-not $responseObject) {
        $approversIncorrect = $true
    }
    else {
        # Test correct approvers are in approval group
        foreach($group in $ApprovalGroups) {
            if($group -notin $responseObject.checkConfiguration.settings.approvers.displayName) {
                $url = "https://dev.azure.com/${Global:organization}/${Global:projectId}/_apis/pipelines/checks/configurations/$($responseObject.checkConfiguration.id)?api-version=5.2-preview.1"
                Invoke-RestMethod -Uri $url -Method 'DELETE' -Headers $headers -SkipCertificateCheck | Out-Null

                $approversIncorrect = $true
                Write-Host "[-] REMOVE: Approval groups $($approverResponse.checkConfiguration.settings.approvers.displayName)" -ForegroundColor "Red"
            }
        }


        # Flip and test the other way that non-required approvers are not in the approval group
        foreach($group in $responseObject.checkConfiguration.settings.approvers.displayName) {
            if($group -notin $ApprovalGroups) {
                $url = "https://dev.azure.com/${Global:organization}/${Global:projectId}/_apis/pipelines/checks/configurations/$($responseObject.checkConfiguration.id)?api-version=5.2-preview.1"
                Invoke-RestMethod -Uri $url -Method 'DELETE' -Headers $headers -SkipCertificateCheck | Out-Null

                $approversIncorrect = $true
                Write-Host "[-] REMOVE: Approval groups $($approverResponse.checkConfiguration.settings.approvers.displayName)" -ForegroundColor "Red"
            }
        }
    }


    # Add custom approvers
    if($approversIncorrect) {
        [array]$groupsArray = @()
        $Global:groups[$Type][$Env].Keys | Select-String -Pattern "Admins" | Foreach-Object {
            $obj              = [PSCustomObject]@{
                "displayName" = "[$Global:project]\$($_)"
                "descriptor"  = $Global:groups[$Type][$Env]["$_"].descriptor
                "id"          = $Global:groups[$Type][$Env]["$_"].id
                "imageUrl"    = "/${Global:organization}/_apis/GraphProfile/MemberAvatars/$($Global:groups[$Type][$Env]["$_"].descriptor)"
            }
            $groupsArray += $obj
        }

        $body = '{
            "type": {
                "name": "Approval"
            },
            "settings": {
                "minRequiredApprovers": 1,
                "requesterCannotBeApprover": true
            },
            "resource": {
                "type": "environment",
                "id": "",
                "name": ""
            },
            "timeout": 30
        }' | ConvertFrom-Json

        $body.resource.id   = $EnvId
        $body.resource.name = $EnvName
        $body.settings | Add-Member -NotePropertyName "approvers" -NotePropertyValue $groupsArray

        Write-Host "[+] ADDING: Approval groups" -ForegroundColor "Green"
        $url = "https://dev.azure.com/${Global:organization}/${Global:projectId}/_apis/pipelines/checks/configurations?api-version=5.2-preview.1"
        Invoke-RestMethod -Uri $url -Method 'POST' -Headers $headers -SkipCertificateCheck -Body $($body | ConvertTo-Json -Depth 10) | Out-Null
    }
    else {
        Write-Host "[!] TESTED: Approval groups" -ForegroundColor "Green"
    }
}



function Add-SomeControl {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]$EnvId
    )


    # Get current branch control
    $url             = "https://dev.azure.com/${Global:organization}/${Global:project}/_environments/${EnvId}/checks?__rt=fps&__ver=2"
    $response        = Invoke-RestMethod -Uri $url -Method 'GET' -Headers $headers
    $responseObject  = $response.fps.dataProviders.data.'ms.vss-pipelinechecks.checks-data-provider'.checkConfigurationDataList |
        Where-Object { $_.checkConfiguration.type.name -eq "Task Check" }

    if($responseObject) {
        foreach($control in $responseObject) {
            if($control.checkConfiguration.settings.inputs.allowedBranches -ne "refs/heads/main, refs/heads/wikiMaster") {
                $url = "https://dev.azure.com/${Global:organization}/${Global:projectId}/_apis/pipelines/checks/configurations/$($control.checkConfiguration.id)?api-version=5.2-preview.1"
                Invoke-RestMethod -Uri $url -Method 'DELETE' -Headers $headers -SkipCertificateCheck | Out-Null

                Write-Host "[-] REMOVE: Branch control $($control.checkConfiguration.settings.inputs.allowedBranches)" -ForegroundColor "Red"
            }
        }
    }


    # RE-list branch control to ensure the correct one remains, or none do and they need to be created (you can have multiple branch control sets)
    $url             = "https://dev.azure.com/${Global:organization}/${Global:project}/_environments/${EnvId}/checks?__rt=fps&__ver=2"
    $response        = Invoke-RestMethod -Uri $url -Method 'GET' -Headers $headers
    $responseObject  = $response.fps.dataProviders.data.'ms.vss-pipelinechecks.checks-data-provider'.checkConfigurationDataList |
        Where-Object { $_.checkConfiguration.type.name -eq "Task Check" }

    if($responseObject) {
        Write-Host "[!] TESTED: Branch control '$($responseObject.checkConfiguration.settings.inputs.allowedBranches)'" -ForegroundColor "Green"
    }
    else {
        # Set branch control

        $body = '
        {
            "type": {
                "name": "Task Check"
            },
            "settings": {
                "definitionRef": {
                    "id": "86b05a0c-73e6-4f7d-b3cf-e38f3b39a75b",
                    "name": "evaluatebranchProtection",
                    "version": "0.0.1"
                },
                "displayName": "Branch control",
                "inputs": {
                    "allowedBranches": "refs/heads/main, refs/heads/wikiMaster",
                    "ensureProtectionOfBranch": "false"
                },
                "retryInterval": 5,
                "linkedVariableGroup": null
            },
            "resource": {
                "type": "environment",
                "id": ""
            },
            "timeout": 30
        }' | ConvertFrom-Json

        $body.resource.id = $EnvId

        Write-Host "[+] ADDING: Branch control" -ForegroundColor "Green"
        $url = "https://dev.azure.com/${Global:organization}/${Global:projectId}/_apis/pipelines/checks/configurations?api-version=5.2-preview.1"
        Invoke-RestMethod -Uri $url -Method 'POST' -Headers $headers -SkipCertificateCheck -Body $($body | ConvertTo-Json -Depth 10) | Out-Null
    }
}




$deleteEnvs            = $Clear
$ErrorActionPreference = "stop"
$Global:organization   = $Org
$Global:project        = $Project


Write-Host "Organisation: " -NoNewline; Write-Host ${Global:organization} -ForegroundColor "Red"
Write-Host "Project     : " -NoNewline; Write-Host ${Global:project}      -ForegroundColor "Red"


$envList = @'
{
    "Env0" : { "approval": false, "branch_control": false, "env_group": "NonProd" },
    "Env1" : { "approval": false, "branch_control": false, "env_group": "NonProd" },
    "Env2" : { "approval": false, "branch_control": false, "env_group": "NonProd" },
    "Env3" : { "approval": false, "branch_control": false, "env_group": "NonProd" },
    "Env4" : { "approval": false, "branch_control": true,  "env_group": "NonProd" },
    "Env5" : { "approval": false, "branch_control": false, "env_group": "NonProd" },
    "Env6" : { "approval": true , "branch_control": true,  "env_group": "PreProd" },
    "Env7" : { "approval": true , "branch_control": true,  "env_group": "Prod"    },
    "Env8" : { "approval": false, "branch_control": false, "env_group": "NonProd" },
    "Env9" : { "approval": true , "branch_control": true,  "env_group": "Prod"    },
    "Env10": { "approval": false, "branch_control": false, "env_group": "NonProd" }
}
'@ | ConvertFrom-Json -AsHashtable


$Global:groups = @'
{
    "Build": {
        "NonProd": {
            "Build_Admins_NP_SeniorEng": {
                "descriptor": "",
                "id": "",
                "role": "Administrator"
            },
            "Build_Admins_NP_SeniorEng_Third_Party": {
                "descriptor": "",
                "id": "",
                "role": "Administrator"
            },
            "Build_Eng_NP": {
                "descriptor": "",
                "id": "",
                "role": "User"
            },
            "Build_Eng_NP_Third_Party": {
                "descriptor": "",
                "id": "",
                "role": "User"
            }
        },
        "PreProd": {
            "Build_Admins_Live_PreProd": {
                "descriptor": "",
                "id": "",
                "role": "Administrator"
            }
        },
        "Prod": {
            "Build_Admins_Live_Prod": {
                "descriptor": "",
                "id": "",
                "role": "Administrator"
            }
        }
    },
    "Release": {
        "NonProd": {
            "Release_Admins_NP_SeniorEng": {
                "descriptor": "",
                "id": "",
                "role": "Administrator"
            },
            "Release_Admins_NP_SeniorEng_Third_Party": {
                "descriptor": "",
                "id": "",
                "role": "Administrator"
            },
            "Release_Eng_NP": {
                "descriptor": "",
                "id": "",
                "role": "User"
            },
            "Release_Eng_NP_Third_Party": {
                "descriptor": "",
                "id": "",
                "role": "User"
            }
        },
        "PreProd": {
            "Release_Admins_Live_PreProd": {
                "descriptor": "",
                "id": "",
                "role": "Administrator"
            }
        },
        "Prod": {
            "Release_Admins_Live_Prod": {
                "descriptor": "",
                "id": "",
                "role": "Administrator"
            }
        }
    }
}
'@ | ConvertFrom-Json -AsHashtable

$defaultGroups = @(
    "[$Global:project]\Contributors"
    "[$Global:project]\Project Administrators"
    "[$Global:project]\Project Valid Users"
)


$base64token = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(":$Token"))
$headers     = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
$headers.Add("Authorization", "Basic $base64token")
$headers.Add("Content-Type", "application/json")


# get project id
$url               = "https://dev.azure.com/${Global:organization}/_apis/projects?api-version=6.1-preview.1"
$response          = Invoke-RestMethod -Uri $url -Method 'GET' -Headers $headers -SkipCertificateCheck
$Global:projectId  = ($response.value | Where-Object { $_.Name -eq $Global:project }).id


# get project descriptor
$url               = "https://vssps.dev.azure.com/${Global:organization}/_apis/graph/descriptors/${Global:projectId}?api-version=6.1-preview.1"
$result            = Invoke-RestMethod -Uri $url -Method 'GET' -Headers $headers -SkipCertificateCheck
$projectDescriptor = $result.value


# list groups
$url               = "https://vssps.dev.azure.com/${Global:organization}/_apis/graph/groups?scopeDescriptor=${projectDescriptor}&api-version=6.1-preview.1"
$response          = Invoke-RestMethod -Uri $url -Method 'GET' -Headers $headers -SkipCertificateCheck
$result            = $response.value


# add IDs & Descriptors to each of the groups
switch($Global:groups.Keys) {
    "Build" {
        foreach($group in $Global:groups["Build"].Keys) {
            foreach($subGroup in $Global:groups["Build"][$group].Keys) {
                $Global:groups["Build"][$group][$subGroup].descriptor = ($result | Where-Object { $_.principalName -eq "[$Global:project]\$subGroup" }).descriptor
                $Global:groups["Build"][$group][$subGroup].id         = ($result | Where-Object { $_.principalName -eq "[$Global:project]\$subGroup" }).originId
            }
        }
    }
    "Release" {
        foreach($group in $Global:groups["Release"].Keys) {
            foreach($subGroup in $Global:groups["Release"][$group].Keys) {
                $Global:groups["Release"][$group][$subGroup].descriptor = ($result | Where-Object { $_.principalName -eq "[$Global:project]\$subGroup" }).descriptor
                $Global:groups["Release"][$group][$subGroup].id         = ($result | Where-Object { $_.principalName -eq "[$Global:project]\$subGroup" }).originId
            }
        }
    }
}


$Global:removeGroups = [PSObject]@{}
foreach($group in $defaultGroups) {
    $Global:removeGroups.Add($group, ($result | Where-Object { $_.principalName -eq $group }).originId)
}


# list envs
$url       = "https://dev.azure.com/${Global:organization}/${Global:project}/_apis/distributedtask/environments?api-version=6.0-preview.1"
$response  = Invoke-RestMethod -Uri $url -Method 'GET' -Headers $headers -SkipCertificateCheck
$result    = $response.value


# delete all envs
if($deleteEnvs) {
    # Only delete those Environments that are listed in $envList (_Build, _Delete, _Release)
    # Leave other Environments alone as not to accidentally delete someone else's

    $deleteList = @()
    foreach($env in $result.name) {
        switch -Regex ($env) {
            "_Build$"   { if( ($envList.Keys -contains $env.Replace("_Build",   "")) -and ($deleteList -notcontains $env)) { $deleteList += $env } }
            "_Delete$"  { if( ($envList.Keys -contains $env.Replace("_Delete",  "")) -and ($deleteList -notcontains $env)) { $deleteList += $env } }
            "_Release$" { if( ($envList.Keys -contains $env.Replace("_Release", "")) -and ($deleteList -notcontains $env)) { $deleteList += $env } }
        }
    }


    Write-Host "`n💣 WARNING!! You are about to .:DESTROY:. the following Environments:`t🤯`n" -ForegroundColor "Red"
    $deleteList
    $reply = Read-Host -Prompt "`nContinue?[y/n]"


    if($reply -match "[yY]" ) {
        Write-Host "`n[!] DELETING ALL ENVIRONMENTS" -ForegroundColor "Red"

        foreach($envDeath in $deleteList) {
            $thisId = ($result | Where-Object { $_.name -eq $envDeath }).id

            Write-Host "💥 ${thisId}: " -ForegroundColor "Yellow" -NoNewline
            Write-Host $envDeath

            $url      = "https://dev.azure.com/${Global:organization}/${Global:project}/_apis/distributedtask/environments/${thisId}?api-version=6.1-preview.1"
            $response = Invoke-RestMethod -Uri $url -Method 'DELETE' -Headers $headers -SkipCertificateCheck
        }
        exit 0
    }
    else {
        Write-Host "`nDon't hurt me! MUMMY!! 😢`n" -ForegroundColor "Magenta"
        exit 0
    }
}
else {
    $Global:groups | ConvertTo-Json -Depth 10
}



foreach($env in $envList.Keys) {
    $envSubList = @(
        "${env}_Build"
        "${env}_Delete"
        "${env}_Release"
    )
    $approval = $envList["$env"].approval
    $control  = $envList["$env"].branch_control
    $envGroup = $envList["$env"].env_group

    foreach($envSub in $envSubList) {
        Write-Host "`n$envSub" -ForegroundColor "Green"
        if($envSub -notin $result.name) {
            Write-Host "[+] ADDING: $envSub in Environments" -ForegroundColor "Green"

            $body      = [PSObject]@{
                "name" = $envSub
            } | ConvertTo-Json


            # create env
            $url      = "https://dev.azure.com/${Global:organization}/${Global:project}/_apis/distributedtask/environments?api-version=6.0-preview.1"
            $response = Invoke-RestMethod $url -Method 'POST' -Headers $headers -SkipCertificateCheck -Body $body
            $envSubId = $response.id
        }
        else {
            $envSubId = ($result | Where-Object { $_.name -eq $envSub }).id
        }

        Write-Host "Environment ID: " -NoNewline
        Write-Host $envSubId -ForegroundColor "Green"


        # List current groups in Environment
        $url              = "https://dev.azure.com/${Global:organization}/_apis/securityroles/scopes/distributedtask.environmentreferencerole/roleassignments/resources/${Global:projectId}_${envSubId}"
        $groupResponse    = Invoke-RestMethod -Uri $url -Method 'GET' -Headers $headers -SkipCertificateCheck
        $Global:groupList = $groupResponse.value.identity.displayName


        $url      = "https://dev.azure.com/${Global:organization}/_apis/securityroles/scopes/distributedtask.environmentreferencerole/roleassignments/resources/${Global:projectId}_${envSubId}?inheritPermissions=false&api-version=5.0-preview.1"
        $response = Invoke-RestMethod -Uri $url -Method 'PATCH' -Headers $headers -SkipCertificateCheck


        function Set-AllTheThings {
            param(
                [Parameter(Mandatory=$true)]
                [ValidateNotNullOrEmpty()]
                [string]$Type
            )

            Add-SomeGroups `
                -Env   $envGroup `
                -EnvId $envSubId `
                -Type  $Type
                if($approval) {
                    Add-SomeApprovers `
                        -EnvId   $envSubId `
                        -EnvName $envSub `
                        -Env     $envGroup
                }
                if($control) {
                        Add-SomeControl -EnvId $envSubId
                }
        }


        switch($envSub) {
            "${env}_Build"   {
                Set-AllTheThings -Type "Build"
            }
            "${env}_Delete"  {
                Set-AllTheThings -Type "Release"
            }
            "${env}_Release" {
                Set-AllTheThings -Type "Release"
            }
        }
    }
}
