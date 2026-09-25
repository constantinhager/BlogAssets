<#
.SYNOPSIS
    One-time setup for GitHub Actions: Entra app with federated credentials (OIDC), RBAC,
    Terraform state storage, SQL admin group and the GitHub repository variables.

.DESCRIPTION
    Idempotent. Run it again to add missing pieces; nothing is deleted.

    Creates or reuses:
    1. Resource provider registrations (azurerm 5.x no longer registers them).
    2. App registration + service principal "<AppName>". No client secret.
    3. Federated credentials for:
         - the GitHub environment (deploy job):  repo:...:environment:<Environment>
         - pull requests (plan job):             repo:...:pull_request
       Subject format: immutable (owner@id/repo@id) for repos created after 2026-07-15
       or opted in; name-based otherwise. See -SubjectFormat.
    4. Role assignments on the subscription:
         - Contributor
         - Role Based Access Control Administrator, constrained by a condition to the
           storage data roles the Terraform code assigns.
    5. Terraform state: resource group, storage account (Entra ID auth only, versioning,
       soft delete), container. Storage Blob Data Contributor for the service principal
       and for you.
    6. Entra security group for the SQL admin, with the service principal and you as members.
    7. With -ConfigureGitHub: GitHub repository variables and the environment (gh CLI).

    Required permissions for the person running it:
    - Owner (or User Access Administrator + Contributor) on the subscription
    - Entra: create applications and groups (default user setting, or Application Developer
      + Groups Administrator)

.PARAMETER Repository
    GitHub repository as owner/name.

.PARAMETER SubscriptionId
    Azure subscription ID where the deployment identity, role assignments,
    Terraform state storage, and SQL admin group are created or reused.

.PARAMETER AppName
    Display name for the Entra app registration and service principal.
    Defaults to gh-<repository-name>-deploy.

.PARAMETER Environment
    GitHub environment name used by the deploy workflow and its federated
    credential. Defaults to csv-upload-to-azure-sql, the environment used by
    .github/workflows/csv-upload-to-azure-sql.yml in the BlogAssets repository.

.PARAMETER Location
    Azure region used when creating the Terraform state resource group or
    storage account. Defaults to germanywestcentral.

.PARAMETER StateResourceGroup
    Resource group that contains the Terraform state storage account.
    Defaults to rg-tfstate.

.PARAMETER StateStorageAccount
    Storage account name for Terraform state. If omitted, the script reuses an
    existing sttfstate* account in the state resource group or generates a new
    compliant name.

.PARAMETER StateContainer
    Blob container name that stores the Terraform state file. Defaults to
    tfstate.

.PARAMETER StateKey
    Blob name of the Terraform state file inside the state container.

.PARAMETER SqlAdminGroupName
    Display name for the Entra security group that becomes the Azure SQL admin
    group. Defaults to sg-<repository-name>-sql-admins.

.PARAMETER SubjectFormat
    Auto: immutable if the repository was created after 2026-07-15, else name-based.
    If the repository opted in to immutable subjects later, pass Immutable.

.PARAMETER ConfigureGitHub
    When set, configures GitHub repository variables and creates the GitHub
    environment by using the gh CLI.

.EXAMPLE
    PS C:\> Connect-AzAccount -Tenant contoso.onmicrosoft.com
    PS C:\> ./scripts/New-GitHubDeploymentIdentity.ps1 -Repository 'contoso/BlogAssets' -SubscriptionId '<sub-id>' `
        -AppName 'gh-blob-to-sql-deploy' -SqlAdminGroupName 'sg-blob-to-sql-sql-admins' -ConfigureGitHub

    The workflow lives in the BlogAssets repository, so the default names (gh-BlogAssets-deploy,
    sg-BlogAssets-sql-admins) would not say which blog post they belong to. Pass explicit names.
#>
#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Resources, Az.Storage
[CmdletBinding(SupportsShouldProcess)]
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
    $Environment = 'csv-upload-to-azure-sql',

    [string]
    $Location = 'germanywestcentral',

    [string]
    $StateResourceGroup = 'rg-tfstate',

    [ValidatePattern('^[a-z0-9]{3,24}$')]
    [string]
    $StateStorageAccount,

    [string]
    $StateContainer = 'tfstate',

    [string]
    $StateKey = 'blob-to-sql.prod.tfstate',

    [string]
    $SqlAdminGroupName,

    [ValidateSet('Auto', 'Immutable', 'Legacy')]
    [string]
    $SubjectFormat = 'Auto',

    [switch]
    $ConfigureGitHub
)

$ErrorActionPreference = 'Stop'
$owner, $repoName = $Repository.Split('/')
if (-not $AppName) { $AppName = "gh-$repoName-deploy" }
if (-not $SqlAdminGroupName) { $SqlAdminGroupName = "sg-$repoName-sql-admins" }

#region Helpers
function Write-Step {
    <#
    .SYNOPSIS
        Writes a highlighted progress message.

    .DESCRIPTION
        Writes a single step marker to the host so long-running setup stages are
        easy to follow while the script runs.

    .PARAMETER Message
        Text to display for the current setup step.
    #>
    param (
        [Parameter(Mandatory)]
        [string]
        $Message
    )

    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-GitHubRepository {
    <#
    .SYNOPSIS
        Retrieves repository metadata from GitHub.

    .DESCRIPTION
        Uses the GitHub CLI when available and falls back to the public GitHub REST
        API. If a `GITHUB_TOKEN` environment variable is present, the REST request
        uses it for authentication.

    .PARAMETER FullName
        Repository name in `owner/name` format.
    #>
    param (
        [Parameter(Mandatory)]
        [string]
        $FullName
    )

    if (Get-Command gh -ErrorAction Ignore) {
        $json = gh api "repos/$FullName"
        if ($LASTEXITCODE -ne 0) { throw "gh api repos/$FullName failed. Run 'gh auth login'." }
        return $json | ConvertFrom-Json
    }
    $headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    if ($env:GITHUB_TOKEN) { $headers.Authorization = "Bearer $env:GITHUB_TOKEN" }
    Invoke-RestMethod -Uri "https://api.github.com/repos/$FullName" -Headers $headers
}

function Add-RoleAssignmentIfMissing {
    <#
    .SYNOPSIS
        Ensures an Azure role assignment exists.

    .DESCRIPTION
        Looks for an existing role assignment for the target principal, role, and
        scope. If none exists, it creates one and retries transient principal
        replication failures that can happen right after a service principal is
        created.

    .PARAMETER ObjectId
        Object ID of the principal that should receive the role assignment.

    .PARAMETER Role
        Role definition name to assign.

    .PARAMETER Scope
        Azure scope where the role assignment should exist.

    .PARAMETER Condition
        Optional RBAC condition expression to apply to the role assignment.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string]
        $ObjectId,

        [Parameter(Mandatory)]
        [string]
        $Role,

        [Parameter(Mandatory)]
        [string]
        $Scope,

        [string]
        $Condition
    )

    $existing = Get-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $Role -Scope $Scope -ErrorAction Ignore |
    Where-Object Scope -EQ $Scope
    if ($existing) { Write-Host "    '$Role' already assigned at $Scope"; return }

    $param = @{ ObjectId = $ObjectId; RoleDefinitionName = $Role; Scope = $Scope }
    if ($Condition) { $param.Condition = $Condition; $param.ConditionVersion = '2.0' }

    # A new service principal can take a moment to replicate
    for ($i = 1; $i -le 6; $i++) {
        try {
            if ($PSCmdlet.ShouldProcess($Scope, "Assign '$Role' to $ObjectId")) { $null = New-AzRoleAssignment @param }
            Write-Host "    '$Role' assigned at $Scope"
            return
        } catch {
            if ($i -eq 6 -or $_.Exception.Message -notmatch 'PrincipalNotFound|does not exist in the directory') { throw }
            Start-Sleep -Seconds 10
        }
    }
}
#endregion Helpers

#region 0. Context
Write-Step 'Azure context'
$context = Get-AzContext
if (-not $context) { $context = (Connect-AzAccount -Subscription $SubscriptionId).Context }
$context = Set-AzContext -Subscription $SubscriptionId
$tenantId = $context.Tenant.Id
$subScope = "/subscriptions/$SubscriptionId"
$me = Get-AzADUser -SignedIn -ErrorAction Ignore
Write-Host "    Tenant $tenantId, subscription $SubscriptionId, signed in as $($context.Account.Id)"

Write-Step "GitHub repository $Repository"
$repo = Get-GitHubRepository -FullName $Repository
$immutable = switch ($SubjectFormat) {
    'Immutable' { $true }
    'Legacy' { $false }
    'Auto' { [datetime]$repo.created_at -gt [datetime]'2026-07-15T00:00:00Z' }
}
$repoSegment = if ($immutable) { "$($repo.owner.login)@$($repo.owner.id)/$($repo.name)@$($repo.id)" } else { "$($repo.owner.login)/$($repo.name)" }
Write-Host "    Repository ID $($repo.id), owner ID $($repo.owner.id), created $($repo.created_at)"
Write-Host "    Subject format: $(if ($immutable) { 'immutable' } else { 'name-based' }) (repo:${repoSegment}:...)"
#endregion 0. Context

#region 1. Resource providers
Write-Step 'Resource providers'
foreach ($namespace in 'Microsoft.Web', 'Microsoft.Storage', 'Microsoft.Sql', 'Microsoft.EventGrid', 'Microsoft.Insights', 'Microsoft.OperationalInsights', 'Microsoft.ManagedIdentity') {
    $state = (Get-AzResourceProvider -ProviderNamespace $namespace | Select-Object -First 1).RegistrationState
    if ($state -ne 'Registered' -and $PSCmdlet.ShouldProcess($namespace, 'Register resource provider')) {
        $null = Register-AzResourceProvider -ProviderNamespace $namespace
        $state = 'Registering'
    }
    Write-Host "    $namespace : $state"
}
#endregion 1. Resource providers

#region 2. App registration + service principal
Write-Step "App registration $AppName"
$app = Get-AzADApplication -DisplayName $AppName | Select-Object -First 1
if (-not $app -and $PSCmdlet.ShouldProcess($AppName, 'Create app registration')) {
    $app = New-AzADApplication -DisplayName $AppName -SignInAudience AzureADMyOrg -Note "GitHub Actions OIDC for $Repository. No secrets."
}
$sp = Get-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction Ignore
if (-not $sp -and $PSCmdlet.ShouldProcess($AppName, 'Create service principal')) {
    $sp = New-AzADServicePrincipal -ApplicationId $app.AppId
}
Write-Host "    Client ID $($app.AppId), SP object ID $($sp.Id)"
#endregion 2. App registration + service principal

#region 3. Federated credentials
Write-Step 'Federated credentials'
$wanted = @(
    @{ Name = "gh-env-$Environment"; Subject = "repo:${repoSegment}:environment:$Environment"; Description = "Deploy job ($Environment environment)" }
    @{ Name = 'gh-pull-request'; Subject = "repo:${repoSegment}:pull_request"; Description = 'Terraform plan on pull requests' }
)
$existing = @(Get-AzADAppFederatedCredential -ApplicationObjectId $app.Id)
foreach ($credential in $wanted) {
    $match = $existing | Where-Object Name -EQ $credential.Name
    if ($match -and $match.Subject -ne $credential.Subject) {
        Write-Warning "    '$($credential.Name)' exists with subject '$($match.Subject)', expected '$($credential.Subject)'. Not changed. Remove it and re-run to replace it."
        continue
    }
    if ($match) { Write-Host "    $($credential.Name): $($credential.Subject) (exists)"; continue }
    if ($PSCmdlet.ShouldProcess($credential.Subject, 'Create federated credential')) {
        $null = New-AzADAppFederatedCredential -ApplicationObjectId $app.Id -Name $credential.Name -Subject $credential.Subject `
            -Issuer 'https://token.actions.githubusercontent.com' -Audience 'api://AzureADTokenExchange' -Description $credential.Description
    }
    Write-Host "    $($credential.Name): $($credential.Subject) (created)"
}
#endregion 3. Federated credentials

#region 4. RBAC on the subscription
Write-Step 'Role assignments'
Add-RoleAssignmentIfMissing -ObjectId $sp.Id -Role 'Contributor' -Scope $subScope

# Only the roles infra/main.tf assigns:
#   ba92f5b4-2d11-453d-a403-e96b0029c9fe  Storage Blob Data Contributor
#   b7e6dc6d-f1e8-4753-8033-0f276bb0955b  Storage Blob Data Owner
#   974c5e8b-45b9-4653-ba55-5f855dd0fb88  Storage Queue Data Contributor
$roleIds = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe, b7e6dc6d-f1e8-4753-8033-0f276bb0955b, 974c5e8b-45b9-4653-ba55-5f855dd0fb88'
$condition = @"
(
 (
  !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
 )
 OR
 (
  @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roleIds}
 )
)
AND
(
 (
  !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
 )
 OR
 (
  @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roleIds}
 )
)
"@
Add-RoleAssignmentIfMissing -ObjectId $sp.Id -Role 'Role Based Access Control Administrator' -Scope $subScope -Condition $condition
#endregion 4. RBAC on the subscription

#region 5. Terraform state storage
Write-Step 'Terraform state storage'
if (-not (Get-AzResourceGroup -Name $StateResourceGroup -ErrorAction Ignore) -and $PSCmdlet.ShouldProcess($StateResourceGroup, 'Create resource group')) {
    $null = New-AzResourceGroup -Name $StateResourceGroup -Location $Location -Tag @{ purpose = 'terraform-state' }
}

if (-not $StateStorageAccount) {
    $StateStorageAccount = (Get-AzStorageAccount -ResourceGroupName $StateResourceGroup -ErrorAction Ignore |
        Where-Object StorageAccountName -Like 'sttfstate*' | Select-Object -First 1).StorageAccountName
    if (-not $StateStorageAccount) {
        $StateStorageAccount = 'sttfstate' + -join ((97..122) + (48..57) | Get-Random -Count 8 | ForEach-Object { [char]$_ })
    }
}

$account = Get-AzStorageAccount -ResourceGroupName $StateResourceGroup -Name $StateStorageAccount -ErrorAction Ignore
if (-not $account -and $PSCmdlet.ShouldProcess($StateStorageAccount, 'Create storage account')) {
    $account = New-AzStorageAccount -ResourceGroupName $StateResourceGroup -Name $StateStorageAccount -Location $Location `
        -SkuName Standard_ZRS -Kind StorageV2 -MinimumTlsVersion TLS1_2 -AllowBlobPublicAccess $false -AllowSharedKeyAccess $false
    $null = Update-AzStorageBlobServiceProperty -ResourceGroupName $StateResourceGroup -StorageAccountName $StateStorageAccount -IsVersioningEnabled $true
    $null = Enable-AzStorageBlobDeleteRetentionPolicy -ResourceGroupName $StateResourceGroup -StorageAccountName $StateStorageAccount -RetentionDays 30
}
# Management-plane container creation: works without data-plane rights
if (-not (Get-AzRmStorageContainer -ResourceGroupName $StateResourceGroup -StorageAccountName $StateStorageAccount -Name $StateContainer -ErrorAction Ignore) -and
    $PSCmdlet.ShouldProcess($StateContainer, 'Create container')) {
    $null = New-AzRmStorageContainer -ResourceGroupName $StateResourceGroup -StorageAccountName $StateStorageAccount -Name $StateContainer
}
Write-Host "    $StateResourceGroup / $StateStorageAccount / $StateContainer"

Add-RoleAssignmentIfMissing -ObjectId $sp.Id -Role 'Storage Blob Data Contributor' -Scope $account.Id
if ($me) { Add-RoleAssignmentIfMissing -ObjectId $me.Id -Role 'Storage Blob Data Contributor' -Scope $account.Id }
#endregion 5. Terraform state storage

#region 6. SQL admin group
Write-Step "SQL admin group $SqlAdminGroupName"
$group = Get-AzADGroup -DisplayName $SqlAdminGroupName | Select-Object -First 1
if (-not $group -and $PSCmdlet.ShouldProcess($SqlAdminGroupName, 'Create security group')) {
    $mailNickname = ($SqlAdminGroupName -replace '[^a-zA-Z0-9-]', '')
    $group = New-AzADGroup -DisplayName $SqlAdminGroupName -MailNickname $mailNickname -SecurityEnabled -Description "Entra admin of the Azure SQL server deployed from $Repository"
}
$memberIds = @(Get-AzADGroupMember -GroupObjectId $group.Id | ForEach-Object Id)
foreach ($memberId in @($sp.Id, $me.Id) | Where-Object { $_ }) {
    if ($memberId -in $memberIds) { continue }
    if ($PSCmdlet.ShouldProcess($SqlAdminGroupName, "Add member $memberId")) {
        Add-AzADGroupMember -TargetGroupObjectId $group.Id -MemberObjectId $memberId
    }
}
Write-Host "    Group object ID $($group.Id), members: service principal$(if ($me) { ', you' })"
#endregion 6. SQL admin group

#region 7. GitHub
$variables = [ordered]@{
    AZURE_CLIENT_ID         = $app.AppId
    AZURE_TENANT_ID         = $tenantId
    AZURE_SUBSCRIPTION_ID   = "$SubscriptionId"
    TFSTATE_RESOURCE_GROUP  = $StateResourceGroup
    TFSTATE_STORAGE_ACCOUNT = $StateStorageAccount
    TFSTATE_CONTAINER       = $StateContainer
    TFSTATE_KEY             = $StateKey
    SQL_ADMIN_GROUP_NAME    = $SqlAdminGroupName
    SQL_ADMIN_GROUP_ID      = $group.Id
}

if ($ConfigureGitHub) {
    Write-Step 'GitHub variables and environment'
    if (-not (Get-Command gh -ErrorAction Ignore)) { throw 'gh CLI not found. Install it or set the variables below manually.' }
    foreach ($name in $variables.Keys) {
        if ($PSCmdlet.ShouldProcess("$Repository : $name", 'Set GitHub variable')) {
            gh variable set $name --body $variables[$name] --repo $Repository
            if ($LASTEXITCODE -ne 0) { throw "gh variable set $name failed" }
        }
    }
    if ($PSCmdlet.ShouldProcess("$Repository : $Environment", 'Create GitHub environment')) {
        $null = gh api --method PUT "repos/$Repository/environments/$Environment"
        if ($LASTEXITCODE -ne 0) { throw "Creating environment '$Environment' failed" }
    }
    Write-Host "    Done. Add required reviewers to the '$Environment' environment in the repository settings if you want an approval gate."
}
#endregion 7. GitHub

Write-Step 'Summary'
[PSCustomObject]$variables | Format-List | Out-String | Write-Host
if (-not $ConfigureGitHub) { Write-Host 'Set these as GitHub repository variables (Settings > Secrets and variables > Actions > Variables), or re-run with -ConfigureGitHub.' }
Write-Host "Local backend.hcl:`n  resource_group_name  = `"$StateResourceGroup`"`n  storage_account_name = `"$StateStorageAccount`"`n  container_name       = `"$StateContainer`"`n  key                  = `"$StateKey`""
