#Requires -Version 7.4
#Requires -Modules Az.Accounts, Az.Resources
<#
.SYNOPSIS
    Removes the Data API builder sample: Terraform resources, the API app registration and,
    optionally, everything New-DabGitHubOidcIdentity.ps1 created.

.DESCRIPTION
    Prefer 'terraform destroy' for the Terraform part. This script is for when the state is
    gone or you want to clean up the bootstrap too. Every step runs only if you pass its
    parameters, asks before it deletes and supports -WhatIf.
    With GitHubOrganization and GitHubRepository, the completed runs of the workflow
    (-WorkflowFileName) are deleted too, with their logs and artifacts; runs in progress are kept.

.EXAMPLE
    $remove = @{
        ResourceGroupName      = 'rg-dab-ab12c'
        ApiClientId            = $apiClientId
        RemovePipelineIdentity = $true
        RemoveSqlAdminGroup    = $true
        RemoveTerraformState   = $true
        GitHubOrganization     = 'constantinhager'
        GitHubRepository       = 'BlogAssets'
    }
    ./scripts/Remove-DabDeployment.ps1 @remove -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [string]
    $ResourceGroupName,

    [Parameter()]
    [guid]
    $ApiClientId,

    [Parameter()]
    [switch]
    $RemovePipelineIdentity,

    [Parameter()]
    [string]
    $PipelineAppDisplayName = 'github-dab-sql-deploy',

    [Parameter()]
    [switch]
    $RemoveSqlAdminGroup,

    [Parameter()]
    [string]
    $SqlAdminGroupName = 'sg-dab-sql-admins',

    [Parameter()]
    [switch]
    $RemoveTerraformState,

    [Parameter()]
    [string]
    $StateResourceGroupName = 'rg-dab-tfstate',

    [Parameter()]
    [string]
    $GitHubOrganization,

    [Parameter()]
    [string]
    $GitHubRepository,

    [Parameter()]
    [string]
    $EnvironmentName = 'production',

    [Parameter()]
    [string]
    $WorkflowFileName = 'data-api-builder.yml'
)

$ErrorActionPreference = 'Stop'
$removed = [System.Collections.Generic.List[string]]::new()

function Invoke-Graph {
    <#
        .SYNOPSIS
        Sends an authenticated request to Microsoft Graph.

        .DESCRIPTION
        Gets a Microsoft Graph access token from the current Azure context and
        invokes the requested Microsoft Graph v1.0 endpoint.

        .PARAMETER Method
        HTTP method to use. Defaults to GET.

        .PARAMETER Path
        Microsoft Graph API path without a leading slash, including the query string.

        .OUTPUTS
        System.Object
        Returns the response from Invoke-RestMethod.

        .EXAMPLE
        Invoke-Graph -Path "applications?`$filter=appId eq '$ApiClientId'"

        .EXAMPLE
        Invoke-Graph -Method DELETE -Path "applications/$objectId"
    #>

    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [Parameter()]
        [string] $Method = 'GET',

        [Parameter(Mandatory)]
        [string]
        $Path
    )
    Invoke-RestMethod -Method $Method -Uri "https://graph.microsoft.com/v1.0/$Path" `
        -Authentication Bearer -Token (Get-AzAccessToken -ResourceTypeName MSGraph).Token
}

function Remove-GraphApplication {
    <#
        .SYNOPSIS
        Deletes an app registration found by an OData filter.

        .DESCRIPTION
        Looks up the first application that matches the filter. Writes a verbose
        message and returns when there is none. Otherwise asks for confirmation
        (ConfirmImpact High) and deletes the application, which also deletes its
        service principal and app role assignments. Adds the label and display name
        to the list of removed items.

        .PARAMETER Filter
        OData filter for the applications endpoint, for example "appId eq '<client-id>'".

        .PARAMETER Label
        Name of the application in messages and in the list of removed items.

        .EXAMPLE
        Remove-GraphApplication -Filter "appId eq '$ApiClientId'" -Label 'API app'

        .EXAMPLE
        Remove-GraphApplication -Filter "displayName eq 'github-dab'" -Label 'Pipeline app' -WhatIf
    #>

    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)]
        [string] $Filter,

        [Parameter(Mandatory)]
        [string] $Label
    )
    
    $app = (Invoke-Graph -Path "applications?`$filter=$Filter&`$select=id,appId,displayName").value | Select-Object -First 1
    if (-not $app) { Write-Verbose "$Label not found."; return }
    if ($PSCmdlet.ShouldProcess("$($app.displayName) ($($app.appId))", "Delete app registration ($Label)")) {
        # Deleting the application also deletes its service principal and app role assignments.
        $null = Invoke-Graph -Method DELETE -Path "applications/$($app.id)"
        $removed.Add("$Label $($app.displayName)")
    }
}

# 1. Azure resources: container app, ACR, SQL, identity, Log Analytics.
if ($ResourceGroupName -and (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue) -and
    $PSCmdlet.ShouldProcess($ResourceGroupName, 'Delete resource group')) {
    $null = Remove-AzResourceGroup -Name $ResourceGroupName -Force
    $removed.Add("Resource group $ResourceGroupName")
}

# 2. The API app registration (created by Terraform, owned by the pipeline identity).
if ($ApiClientId) { Remove-GraphApplication -Filter "appId eq '$ApiClientId'" -Label 'API app' }

# 3. Pipeline identity and its role assignments.
if ($RemovePipelineIdentity) {
    $sp = (Invoke-Graph -Path "servicePrincipals?`$filter=displayName eq '$PipelineAppDisplayName'&`$select=id").value | Select-Object -First 1
    if ($sp) {
        foreach ($assignment in Get-AzRoleAssignment -ObjectId $sp.id -ErrorAction SilentlyContinue) {
            if ($PSCmdlet.ShouldProcess("$($assignment.RoleDefinitionName) on $($assignment.Scope)", 'Remove role assignment')) {
                $assignment | Remove-AzRoleAssignment | Out-Null
                $removed.Add("Role assignment $($assignment.RoleDefinitionName)")
            }
        }
    }
    Remove-GraphApplication -Filter "displayName eq '$PipelineAppDisplayName'" -Label 'Pipeline app'
}

# 4. SQL admin group.
if ($RemoveSqlAdminGroup) {
    $group = (Invoke-Graph -Path "groups?`$filter=displayName eq '$SqlAdminGroupName'&`$select=id").value | Select-Object -First 1
    if ($group -and $PSCmdlet.ShouldProcess($SqlAdminGroupName, 'Delete group')) {
        $null = Invoke-Graph -Method DELETE -Path "groups/$($group.id)"
        $removed.Add("Group $SqlAdminGroupName")
    }
}

# 5. Terraform state.
if ($RemoveTerraformState -and (Get-AzResourceGroup -Name $StateResourceGroupName -ErrorAction SilentlyContinue) -and
    $PSCmdlet.ShouldProcess($StateResourceGroupName, 'Delete Terraform state resource group')) {
    $null = Remove-AzResourceGroup -Name $StateResourceGroupName -Force
    $removed.Add("State resource group $StateResourceGroupName")
}

# 6. GitHub variables, environment and workflow runs.
if ($GitHubOrganization -and $GitHubRepository) {
    $repo = "$GitHubOrganization/$GitHubRepository"
    $variables = 'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'TFSTATE_RESOURCE_GROUP',
                 'TFSTATE_STORAGE_ACCOUNT', 'SQL_ADMIN_GROUP_NAME', 'SQL_ADMIN_GROUP_ID'
    if ($PSCmdlet.ShouldProcess($repo, 'Delete repository variables and environment')) {
        foreach ($name in $variables) { gh variable delete $name --repo $repo 2>$null }
        gh api --method DELETE "repos/$repo/environments/$EnvironmentName" --silent 2>$null
        $removed.Add("GitHub variables and environment in $repo")
    }

    # Deleting a run also deletes its logs and artifacts (dacpac, tfplan). Runs in progress are kept.
    $runs = @(gh api --paginate "repos/$repo/actions/workflows/$WorkflowFileName/runs?per_page=100" --jq '.workflow_runs[] | {id, status}' 2>$null |
        ConvertFrom-Json)
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Listing the runs of $WorkflowFileName in $repo failed - runs kept."
    }
    elseif ($runs.Count -gt 0 -and $PSCmdlet.ShouldProcess("$repo $WorkflowFileName", "Delete $($runs.Count) workflow run(s) including logs and artifacts")) {
        $deleted = 0
        foreach ($run in $runs) {
            if ($run.status -ne 'completed') {
                Write-Warning "Run $($run.id) is $($run.status) - kept."
                continue
            }
            gh api --method DELETE "repos/$repo/actions/runs/$($run.id)" --silent
            if ($LASTEXITCODE -ne 0) {
                Write-Warning "Deleting run $($run.id) failed."
                continue
            }
            $deleted++
        }
        $removed.Add("$deleted workflow run(s) of $WorkflowFileName in $repo")
    }
}

[pscustomobject]@{ Removed = $removed.ToArray() }
