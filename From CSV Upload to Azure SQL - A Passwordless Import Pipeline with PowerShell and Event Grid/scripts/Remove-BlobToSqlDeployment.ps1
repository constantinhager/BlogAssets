<#
.SYNOPSIS
    Removes everything this project created in Azure, Entra ID and GitHub.

.DESCRIPTION
    Counterpart to New-GitHubDeploymentIdentity.ps1 and the Terraform deployment.
    Idempotent. Anything that no longer exists is skipped.

    Removes, in this order:
    1. The Terraform resource group(s) rg-<Prefix>-* tagged workload=<WorkloadTag>. This deletes
       the Function App, SQL server and database, storage accounts, Event Grid, monitoring, the
       user-assigned identity, and the role assignments scoped to those resources.
    2. The Terraform state resource group <StateResourceGroup> with the state storage account
       and every state file in it.
    3. All remaining role assignments of the deployment service principal in the subscription
       (Contributor, Role Based Access Control Administrator).
    4. The Entra SQL admin group.
    5. The app registration. This also deletes its service principal and federated credentials.
    6. GitHub: the environment <Environment> and ALL repository variables of <Repository>,
       including variables that other workflows set.
    7. With -RemoveWorkflowRuns: all runs of the workflow <WorkflowFile>, with their logs and
       artifacts. Runs that are still in progress are skipped.

    Not removed: resource provider registrations (shared by the whole subscription).

    Soft delete: the app registration stays in Entra "Deleted applications" for 30 days.

.PARAMETER Repository
    GitHub repository as owner/name. Used for the default names and for the GitHub cleanup.

.PARAMETER SubscriptionId
    Azure subscription ID the project was deployed to.

.PARAMETER AppName
    Display name of the app registration. Defaults to gh-<repository-name>-deploy.

.PARAMETER SqlAdminGroupName
    Display name of the SQL admin group. Defaults to sg-<repository-name>-sql-admins.

.PARAMETER Environment
    GitHub environment of the deploy job. Defaults to csv-upload-to-azure-sql.

.PARAMETER Prefix
    Terraform variable prefix. The resource group is named rg-<Prefix>-<suffix>. Defaults to blob2sql.

.PARAMETER WorkloadTag
    Value of the workload tag on the Terraform resource group. Defaults to blob-to-sql.

.PARAMETER StateResourceGroup
    Resource group of the Terraform state storage account. Defaults to rg-tfstate.

.PARAMETER RemoveWorkflowRuns
    Also delete the run history of the workflow <WorkflowFile> on GitHub. Asks once for all runs.

.PARAMETER WorkflowFile
    File name of the workflow whose runs -RemoveWorkflowRuns deletes. Defaults to csv-upload-to-azure-sql.yml.

.EXAMPLE
    PS C:\> $cleanup = @{
                Repository        = 'contoso/BlogAssets'
                SubscriptionId    = '<sub-id>'
                AppName           = 'gh-blob-to-sql-deploy'
                SqlAdminGroupName = 'sg-blob-to-sql-sql-admins'
                WhatIf            = $true
            }
    PS C:\> ./scripts/Remove-BlobToSqlDeployment.ps1 @cleanup

    Shows what would be removed. Run it again without WhatIf to remove it. Every deletion asks
    for confirmation; add Confirm = $false to skip the prompts.

.EXAMPLE
    PS C:\> $cleanup = @{
                Repository         = 'contoso/BlogAssets'
                SubscriptionId     = '<sub-id>'
                RemoveWorkflowRuns = $true
            }
    PS C:\> ./scripts/Remove-BlobToSqlDeployment.ps1 @cleanup

    Removes everything, including the run history of the deploy workflow on GitHub.
#>
#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Resources
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param (
    [Parameter(Mandatory)]
    [ValidatePattern('^[\w.-]+/[\w.-]+$')]
    [string]
    $Repository,

    [Parameter(Mandatory)]
    [guid]
    $SubscriptionId,

    [string]
    $AppName,

    [string]
    $SqlAdminGroupName,

    [string]
    $Environment = 'csv-upload-to-azure-sql',

    [string]
    $Prefix = 'blob2sql',

    [string]
    $WorkloadTag = 'blob-to-sql',

    [string]
    $StateResourceGroup = 'rg-tfstate',

    [switch]
    $RemoveWorkflowRuns,

    [string]
    $WorkflowFile = 'csv-upload-to-azure-sql.yml'
)

$ErrorActionPreference = 'Stop'
$owner, $repoName = $Repository.Split('/')
if (-not $AppName) {
    $AppName = "gh-$repoName-deploy"
}
if (-not $SqlAdminGroupName) {
    $SqlAdminGroupName = "sg-$repoName-sql-admins"
}

function Write-Step {
    <#
    .SYNOPSIS
        Writes a highlighted progress message.

    .PARAMETER Message
        Text to display for the current step.
    #>
    param (
        [Parameter(Mandatory)]
        [string]
        $Message
    )

    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Remove-ResourceGroupIfPresent {
    <#
    .SYNOPSIS
        Deletes a resource group and everything in it, if it exists.

    .PARAMETER Name
        Name of the resource group.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param (
        [Parameter(Mandatory)]
        [string]
        $Name
    )

    if (-not (Get-AzResourceGroup -Name $Name -ErrorAction Ignore)) {
        Write-Host "    $Name not found"
        return
    }
    if ($PSCmdlet.ShouldProcess($Name, 'Delete resource group and all its resources')) {
        Write-Host "    Deleting $Name. This takes several minutes."
        $null = Remove-AzResourceGroup -Name $Name -Force
        Write-Host "    $Name deleted"
    }
}

#region 0. Context
Write-Step 'Azure context'
$context = Get-AzContext
if (-not $context) {
    $context = (Connect-AzAccount -Subscription $SubscriptionId).Context
}
# Switching the context changes nothing in Azure, so it also runs under -WhatIf
$context = Set-AzContext -Subscription $SubscriptionId -WhatIf:$false
Write-Host "    Tenant $($context.Tenant.Id), subscription $SubscriptionId, signed in as $($context.Account.Id)"

$app = Get-AzADApplication -DisplayName $AppName | Select-Object -First 1
$sp = $null
if ($app) {
    $sp = Get-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction Ignore
}
#endregion 0. Context

#region 1. Terraform resource group
Write-Step "Terraform resource group rg-$Prefix-* (workload=$WorkloadTag)"
$resourceGroups = @(
    Get-AzResourceGroup | Where-Object {
        $_.ResourceGroupName -like "rg-$Prefix-*" -and $_.Tags.workload -eq $WorkloadTag
    }
)
if (-not $resourceGroups) {
    Write-Host '    None found'
}
foreach ($resourceGroup in $resourceGroups) {
    Remove-ResourceGroupIfPresent -Name $resourceGroup.ResourceGroupName
}
#endregion 1. Terraform resource group

#region 2. Terraform state
Write-Step "Terraform state resource group $StateResourceGroup"
Remove-ResourceGroupIfPresent -Name $StateResourceGroup
#endregion 2. Terraform state

#region 3. Role assignments of the service principal
Write-Step 'Role assignments of the deployment service principal'
if (-not $sp) {
    Write-Host "    Service principal for $AppName not found"
} else {
    $assignments = @(Get-AzRoleAssignment -ObjectId $sp.Id -ErrorAction Ignore)
    if (-not $assignments) {
        Write-Host '    None found'
    }
    foreach ($assignment in $assignments) {
        if ($PSCmdlet.ShouldProcess($assignment.Scope, "Remove '$($assignment.RoleDefinitionName)' from $AppName")) {
            $removeParam = @{
                ObjectId           = $sp.Id
                RoleDefinitionName = $assignment.RoleDefinitionName
                Scope              = $assignment.Scope
            }
            $null = Remove-AzRoleAssignment @removeParam
            Write-Host "    '$($assignment.RoleDefinitionName)' removed at $($assignment.Scope)"
        }
    }
}
#endregion 3. Role assignments of the service principal

#region 4. SQL admin group
Write-Step "SQL admin group $SqlAdminGroupName"
$group = Get-AzADGroup -DisplayName $SqlAdminGroupName | Select-Object -First 1
if (-not $group) {
    Write-Host '    Not found'
} elseif ($PSCmdlet.ShouldProcess($SqlAdminGroupName, 'Delete Entra group')) {
    Remove-AzADGroup -ObjectId $group.Id
    Write-Host "    $SqlAdminGroupName deleted"
}
#endregion 4. SQL admin group

#region 5. App registration
Write-Step "App registration $AppName"
if (-not $app) {
    Write-Host '    Not found'
} elseif ($PSCmdlet.ShouldProcess($AppName, 'Delete app registration, service principal and federated credentials')) {
    Remove-AzADApplication -ObjectId $app.Id
    Write-Host "    $AppName deleted (recoverable for 30 days under Entra > Deleted applications)"
}
#endregion 5. App registration

#region 6. GitHub
Write-Step 'GitHub environment and variables'
if (-not (Get-Command gh -ErrorAction Ignore)) {
    throw 'gh CLI not found. Install it or remove the environment and variables manually.'
}

if ($PSCmdlet.ShouldProcess("$Repository : $Environment", 'Delete GitHub environment')) {
    $null = gh api --method DELETE "repos/$Repository/environments/$Environment" 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    Environment $Environment deleted"
    } else {
        Write-Host "    Environment $Environment not found"
    }
}

$variableNames = @(gh variable list --repo $Repository --json name --jq '.[].name')
if ($LASTEXITCODE -ne 0) {
    throw "gh variable list failed for $Repository. Run 'gh auth login'."
}
if (-not $variableNames) {
    Write-Host '    No repository variables'
}
foreach ($name in $variableNames) {
    if ($PSCmdlet.ShouldProcess("$Repository : $name", 'Delete GitHub repository variable')) {
        $null = gh variable delete $name --repo $Repository
        if ($LASTEXITCODE -ne 0) {
            throw "gh variable delete $name failed"
        }
        Write-Host "    $name deleted"
    }
}
#endregion 6. GitHub

#region 7. Workflow runs
if ($RemoveWorkflowRuns) {
    Write-Step "GitHub workflow runs of $WorkflowFile"
    $runListArgs = @(
        'run', 'list'
        '--repo', $Repository
        '--workflow', $WorkflowFile
        '--limit', '1000'
        '--json', 'databaseId,status'
    )
    $runs = @(gh @runListArgs | ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0) {
        throw "gh run list failed for $WorkflowFile in $Repository"
    }
    $running = @($runs | Where-Object status -NE 'completed')
    $completed = @($runs | Where-Object status -EQ 'completed')
    if ($running) {
        Write-Warning "$($running.Count) run(s) still in progress, skipped. Cancel them or run the script again later."
    }
    if (-not $completed) {
        Write-Host '    No completed runs'
    } elseif ($PSCmdlet.ShouldProcess("$Repository : $WorkflowFile", "Delete $($completed.Count) workflow run(s) with logs and artifacts")) {
        $failed = 0
        foreach ($run in $completed) {
            $null = gh api --method DELETE "repos/$Repository/actions/runs/$($run.databaseId)" 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Could not delete run $($run.databaseId)"
                $failed++
            }
        }
        Write-Host "    $($completed.Count - $failed) run(s) deleted"
    }
}
#endregion 7. Workflow runs

Write-Step 'Done'
