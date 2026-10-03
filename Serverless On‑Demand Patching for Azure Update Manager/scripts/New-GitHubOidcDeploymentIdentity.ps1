<#
.SYNOPSIS
	Pre-provisions everything GitHub Actions needs to deploy this project to Azure - without any secret.

.DESCRIPTION
	Run this once, before the first workflow run. It creates (idempotent, safe to re-run):

	1. An Entra ID app registration + service principal for GitHub Actions
	2. Federated identity credentials (OIDC) for:
	   - pushes to the main branch           repo:<org>/<repo>:ref:refs/heads/main
	   - pull requests                       repo:<org>/<repo>:pull_request
	   - the GitHub environment (deployment) repo:<org>/<repo>:environment:<env>

	   If the repository uses immutable IDs in the OIDC subject claim, pass -GitHubOrganizationId and
	   -GitHubRepositoryId, or let the script look them up with the GitHub CLI (-ResolveGitHubId).
	   The subjects then look like repo:<org>@<orgId>/<repo>@<repoId>:pull_request.
	   A credential with the same name but another subject is updated, so re-running fixes old credentials.
	3. Resource provider registrations (Microsoft.Maintenance, Microsoft.HybridCompute, ...)
	4. A storage account + container for the Terraform state (Entra ID auth only, no shared keys)
	5. Role assignments for the service principal:
	   - Contributor                      on the subscription
	   - User Access Administrator        on the subscription, constrained by a condition:
	                                      it may NOT assign Owner, User Access Administrator or
	                                      Role Based Access Control Administrator
	   - Storage Blob Data Contributor    on the state storage account
	6. Optional (-ConfigureGitHub): GitHub repository variables + the GitHub environment via the gh CLI

	All Azure and Entra ID calls use the Az PowerShell modules (Az.Accounts, Az.Resources, Az.Storage).
	Sign in first with Connect-AzAccount.

	Required rights of the person running the script:
	- Entra ID: Application Developer (or Application Administrator) to create the app
	- Azure: Owner (or User Access Administrator + Contributor) on the subscription

.PARAMETER GitHubOrganization
	GitHub user or organization that owns the repository.

.PARAMETER GitHubRepository
	Repository name.

.PARAMETER GitHubOrganizationId
	Numeric ID of the GitHub user or organization (owner ID). Use it together with GitHubRepositoryId when the
	OIDC subject claim contains immutable IDs. Without it, Entra ID rejects the token with
	AADSTS700213 (no matching federated identity record).
	Find it with: gh api repos/<org>/<repo> --jq .owner.id

.PARAMETER GitHubRepositoryId
	Numeric ID of the repository. Use it together with GitHubOrganizationId.
	Find it with: gh api repos/<org>/<repo> --jq .id

.PARAMETER ResolveGitHubId
	Look up the owner ID and the repository ID with the GitHub CLI (gh api repos/<org>/<repo>) instead of
	passing them. The GitHub CLI must be installed and signed in (gh auth login). The owner and repository
	names are taken from the GitHub response, so their casing matches the OIDC subject.

.PARAMETER SubscriptionId
	Target subscription. Defaults to the current Az context subscription.

.PARAMETER AppDisplayName
	Display name of the app registration.

.PARAMETER GitHubEnvironment
	Name of the GitHub environment used by the apply / deploy jobs.

.PARAMETER Location
	Region for the Terraform state storage account.

.PARAMETER StateResourceGroupName
	Resource group for the Terraform state.

.PARAMETER StateStorageAccountName
	Name of the state storage account. Defaults to 'sttfstate' + 6 random characters.

.PARAMETER StateContainerName
	Blob container for the state file.

.PARAMETER SkipRoleAssignmentCondition
	Assign User Access Administrator without the condition that blocks privileged roles.

.PARAMETER ConfigureGitHub
	Write the IDs as repository variables and create the environment with the GitHub CLI (gh).

.EXAMPLE
	PS C:\> Connect-AzAccount
	PS C:\> $identity = @{
		GitHubOrganization = 'contoso'
		GitHubRepository   = 'AzureUpdateManagerAutomation'
		ConfigureGitHub    = $true
	}
	PS C:\> ./New-GitHubOidcDeploymentIdentity.ps1 @identity

	Creates the identity, the state storage, and configures the GitHub repository.

.EXAMPLE
	PS C:\> $identity = @{
		GitHubOrganization      = 'contoso'
		GitHubRepository        = 'AzureUpdateManagerAutomation'
		SubscriptionId          = '00000000-0000-0000-0000-000000000000'
		GitHubEnvironment       = 'production'
		Location                = 'westeurope'
		StateResourceGroupName  = 'rg-aum-tfstate'
		StateStorageAccountName = 'sttfstatecontoso'
		StateContainerName      = 'tfstate'
	}
	PS C:\> ./New-GitHubOidcDeploymentIdentity.ps1 @identity

	Uses a specific subscription, region and state storage account.
	The GitHub environment and repository variables are not written; the script prints the values instead.

.EXAMPLE
	PS C:\> $identity = @{
		GitHubOrganization = 'contoso'
		GitHubRepository   = 'AzureUpdateManagerAutomation'
		ResolveGitHubId    = $true
		ConfigureGitHub    = $true
	}
	PS C:\> ./New-GitHubOidcDeploymentIdentity.ps1 @identity

	Looks up the owner and repository ID with the GitHub CLI and creates (or updates) the federated credentials
	with immutable-ID subjects, e.g. repo:contoso@123456/AzureUpdateManagerAutomation@987654321:pull_request.

.EXAMPLE
	PS C:\> $identity = @{
		GitHubOrganization   = 'contoso'
		GitHubRepository     = 'AzureUpdateManagerAutomation'
		GitHubOrganizationId = 123456
		GitHubRepositoryId   = 987654321
	}
	PS C:\> ./New-GitHubOidcDeploymentIdentity.ps1 @identity

	Same result, with the IDs passed explicitly (no GitHub CLI needed).
#>
#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Resources, Az.Storage
[CmdletBinding(DefaultParameterSetName = 'Default')]
[OutputType([pscustomobject])]
param (
	[Parameter(Mandatory)]
	[ValidatePattern('^[A-Za-z0-9-]{1,39}$', ErrorMessage = "'{0}' is not a valid GitHub user or organization name.")]
	[string]
	$GitHubOrganization,

	[Parameter(Mandatory)]
	[ValidatePattern('^[A-Za-z0-9._-]{1,100}$', ErrorMessage = "'{0}' is not a valid GitHub repository name.")]
	[string]
	$GitHubRepository,

	[Parameter(ParameterSetName = 'ImmutableSubject', Mandatory)]
	[ValidateRange(1, [long]::MaxValue)]
	[long]
	$GitHubOrganizationId,

	[Parameter(ParameterSetName = 'ImmutableSubject', Mandatory)]
	[ValidateRange(1, [long]::MaxValue)]
	[long]
	$GitHubRepositoryId,

	[Parameter(ParameterSetName = 'LookupImmutableSubject', Mandatory)]
	[switch]
	$ResolveGitHubId,

	[Parameter()]
	[ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$', ErrorMessage = "'{0}' is not a valid subscription ID (GUID).")]
	[string]
	$SubscriptionId,

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[ValidateLength(1, 120)]
	[string]
	$AppDisplayName = "github-oidc-$GitHubRepository",

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]
	$GitHubEnvironment = 'production',

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]
	$Location = 'germanywestcentral',

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[ValidateLength(1, 90)]
	[string]
	$StateResourceGroupName = 'rg-aum-tfstate',

	[Parameter()]
	[ValidatePattern('^[a-z0-9]{3,24}$')]
	[string]
	$StateStorageAccountName,

	[Parameter()]
	[ValidatePattern('^[a-z0-9](?:[a-z0-9]|-(?!-)){1,61}[a-z0-9]$', ErrorMessage = "'{0}' is not a valid blob container name (3-63 lowercase letters, digits, single hyphens).")]
	[string]
	$StateContainerName = 'tfstate',

	[Parameter()]
	[switch]
	$SkipRoleAssignmentCondition,

	[Parameter()]
	[switch]
	$ConfigureGitHub
)

$ErrorActionPreference = 'Stop'

#region Helpers
function Set-RoleAssignment {
	<#
	.SYNOPSIS
		Creates an Azure role assignment for a service principal, if it does not exist yet.

	.DESCRIPTION
		Idempotent wrapper around New-AzRoleAssignment. It first looks for an assignment of the same
		role to the same principal at exactly the same scope (inherited assignments do not count).
		If none exists, it creates one, optionally with an ABAC condition (condition version 2.0).

		A brand-new service principal needs a moment to replicate in Entra ID. The function therefore
		retries up to 10 times, 10 seconds apart, while the principal is not found yet.
		An assignment that appears in the meantime is treated as success.

		The description of the assignment is built from the script-level parameters
		GitHubOrganization and GitHubRepository.

	.PARAMETER Scope
		Resource ID of the scope, for example '/subscriptions/<id>' or a storage account resource ID.

	.PARAMETER RoleDefinitionGuid
		GUID of the built-in or custom role definition.

	.PARAMETER PrincipalId
		Object ID of the service principal that receives the role.

	.PARAMETER RoleName
		Display name of the role. Only used for the progress output.

	.PARAMETER Condition
		Optional ABAC condition that restricts the assignment, for example to block privileged roles.

	.EXAMPLE
		PS C:\> $assignment = @{
			Scope              = "/subscriptions/$SubscriptionId"
			RoleDefinitionGuid = $roles.Contributor
			PrincipalId        = $sp.Id
			RoleName           = 'Contributor'
		}
		PS C:\> Set-RoleAssignment @assignment

		Assigns Contributor on the subscription, unless it is already assigned there.

	.EXAMPLE
		PS C:\> $assignment = @{
			Scope              = $subscriptionScope
			RoleDefinitionGuid = $roles.UserAccessAdministrator
			PrincipalId        = $sp.Id
			RoleName           = 'User Access Administrator (constrained)'
			Condition          = $condition
		}
		PS C:\> Set-RoleAssignment @assignment

		Assigns User Access Administrator, limited by the ABAC condition.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]
		$Scope,

		[Parameter(Mandatory)]
		[guid]
		$RoleDefinitionGuid,

		[Parameter(Mandatory)]
		[guid]
		$PrincipalId,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]
		$RoleName,

		[Parameter()]
		[string]
		$Condition
	)

	$existingAssignment = Get-AzRoleAssignment -ObjectId $PrincipalId -RoleDefinitionId $RoleDefinitionGuid -Scope $Scope -ErrorAction Ignore |
		Where-Object Scope -eq $Scope
	if ($existingAssignment) {
		Write-Host "  [ok] $RoleName on $Scope (exists)"
		return
	}

	$param = @{
		ObjectId         = $PrincipalId
		ObjectType       = 'ServicePrincipal'
		RoleDefinitionId = $RoleDefinitionGuid
		Scope            = $Scope
		Description      = "GitHub Actions deployment identity for $GitHubOrganization/$GitHubRepository"
	}
	if ($Condition) {
		$param.Condition = $Condition
		$param.ConditionVersion = '2.0'
	}

	# A brand-new service principal needs a moment to replicate -> retry while it is not found
	for ($attempt = 1; $attempt -le 10; $attempt++) {
		try {
			$null = New-AzRoleAssignment @param
			Write-Host "  [ok] $RoleName on $Scope"
			return
		}
		catch {
			if ($_.Exception.Message -match 'already exists') { Write-Host "  [ok] $RoleName on $Scope (exists)"; return }
			if ($_.Exception.Message -notmatch 'PrincipalNotFound|does not exist in the directory') { throw }
			Write-Host "  ... waiting for service principal replication ($attempt/10)"
			Start-Sleep -Seconds 10
		}
	}
	throw "Role assignment $RoleName on $Scope failed: service principal not found after retries."
}
#endregion Helpers

#region Context
$context = Get-AzContext
if (-not $context) { throw "Not signed in. Run 'Connect-AzAccount' first." }
if ($SubscriptionId -and $SubscriptionId -ne $context.Subscription.Id) {
	$context = Set-AzContext -Subscription $SubscriptionId
}
$SubscriptionId = $context.Subscription.Id
$tenantId = $context.Tenant.Id
if (-not $StateStorageAccountName) {
	$StateStorageAccountName = 'sttfstate' + -join ((97..122) + (48..57) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
}
if ($ResolveGitHubId) {
	if (-not (Get-Command gh -ErrorAction Ignore)) { throw 'GitHub CLI (gh) not found. Install it or pass -GitHubOrganizationId and -GitHubRepositoryId.' }
	$repositoryJson = gh api "repos/$GitHubOrganization/$GitHubRepository"
	if ($LASTEXITCODE -ne 0) { throw "Could not read repos/$GitHubOrganization/$GitHubRepository with the GitHub CLI. Run 'gh auth login' and check the names." }
	$repositoryInfo = $repositoryJson | ConvertFrom-Json
	$GitHubOrganization = $repositoryInfo.owner.login
	$GitHubRepository = $repositoryInfo.name
	$GitHubOrganizationId = $repositoryInfo.owner.id
	$GitHubRepositoryId = $repositoryInfo.id
}
$repoFullName = "$GitHubOrganization/$GitHubRepository"
# The OIDC subject either carries the names only, or the names plus the immutable numeric IDs.
$repoSubject = "repo:$repoFullName"
if ($PSCmdlet.ParameterSetName -in 'ImmutableSubject', 'LookupImmutableSubject') {
	$repoSubject = "repo:$GitHubOrganization@$GitHubOrganizationId/$GitHubRepository@$GitHubRepositoryId"
}
Write-Host "Tenant: $tenantId | Subscription: $SubscriptionId | Repository: $repoFullName | Subject prefix: $repoSubject"
#endregion Context

#region 1. App registration + service principal
Write-Host "`n[1/6] App registration '$AppDisplayName'"
$app = Get-AzADApplication -DisplayName $AppDisplayName | Where-Object DisplayName -eq $AppDisplayName | Select-Object -First 1
if (-not $app) {
	$app = New-AzADApplication -DisplayName $AppDisplayName -SignInAudience 'AzureADMyOrg' -Description "GitHub Actions OIDC identity for $repoFullName. Created by New-GitHubOidcDeploymentIdentity.ps1"
	Write-Host "  [new] appId $($app.AppId)"
}
else { Write-Host "  [ok] appId $($app.AppId) (exists)" }

$sp = Get-AzADServicePrincipal -ApplicationId $app.AppId
if (-not $sp) {
	$sp = New-AzADServicePrincipal -ApplicationId $app.AppId
	Write-Host "  [new] service principal $($sp.Id)"
}
else { Write-Host "  [ok] service principal $($sp.Id) (exists)" }
#endregion

#region 2. Federated identity credentials
Write-Host "`n[2/6] Federated identity credentials"
$desired = @(
	@{ name = 'github-branch-main'; subject = "$($repoSubject):ref:refs/heads/main"; description = 'Pushes to main' }
	@{ name = 'github-pull-request'; subject = "$($repoSubject):pull_request"; description = 'Pull requests (terraform plan)' }
	@{ name = "github-env-$GitHubEnvironment"; subject = "$($repoSubject):environment:$GitHubEnvironment"; description = "GitHub environment '$GitHubEnvironment' (apply / deploy)" }
)
$existing = @(Get-AzADAppFederatedCredential -ApplicationObjectId $app.Id)
foreach ($credential in $desired) {
	$sameName = $existing | Where-Object Name -eq $credential.name | Select-Object -First 1
	if ($sameName -and $sameName.Subject -eq $credential.subject) {
		Write-Host "  [ok] $($credential.subject) (exists)"
		continue
	}
	if ($sameName) {
		# Credential names are unique per app: fix the subject of the existing one instead of creating a duplicate
		$null = Update-AzADAppFederatedCredential -ApplicationObjectId $app.Id -FederatedCredentialId $sameName.Id -Subject $credential.subject
		Write-Host "  [update] $($credential.name): $($sameName.Subject) -> $($credential.subject)"
		continue
	}
	if ($existing.Subject -contains $credential.subject) {
		Write-Host "  [ok] $($credential.subject) (exists under another name)"
		continue
	}
	$null = New-AzADAppFederatedCredential -ApplicationObjectId $app.Id -Name $credential.name -Issuer 'https://token.actions.githubusercontent.com' -Subject $credential.subject -Audience 'api://AzureADTokenExchange' -Description $credential.description
	Write-Host "  [new] $($credential.subject)"
}
#endregion

#region 3. Resource providers
Write-Host "`n[3/6] Resource provider registrations"
$providers = 'Microsoft.Maintenance', 'Microsoft.HybridCompute', 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.Web', 'Microsoft.Insights', 'Microsoft.OperationalInsights'
foreach ($provider in $providers) {
	$null = Register-AzResourceProvider -ProviderNamespace $provider
	Write-Host "  [ok] $provider"
}
#endregion

#region 4. Terraform state storage
Write-Host "`n[4/6] Terraform state storage"
$null = New-AzResourceGroup -Name $StateResourceGroupName -Location $Location -Tag @{ purpose = 'terraform-state' } -Force
Write-Host "  [ok] resource group $StateResourceGroupName"

# Re-use an existing state account in the resource group, if there is one
$accounts = @(Get-AzStorageAccount -ResourceGroupName $StateResourceGroupName)
if ($accounts -and -not $PSBoundParameters.ContainsKey('StateStorageAccountName')) {
	$StateStorageAccountName = $accounts[0].StorageAccountName
}

if (-not ($accounts | Where-Object StorageAccountName -eq $StateStorageAccountName)) {
	$null = New-AzStorageAccount -ResourceGroupName $StateResourceGroupName -Name $StateStorageAccountName -Location $Location `
		-SkuName Standard_LRS -Kind StorageV2 -Tag @{ purpose = 'terraform-state' } `
		-MinimumTlsVersion TLS1_2 `
		-AllowBlobPublicAccess $false `
		-AllowSharedKeyAccess $false `
		-EnableHttpsTrafficOnly $true
	Write-Host "  [new] storage account $StateStorageAccountName"
}
else { Write-Host "  [ok] storage account $StateStorageAccountName (exists)" }

# Entra ID only - the backend uses use_azuread_auth. The container is managed through ARM, so no shared key or data-plane role is needed.
$null = Update-AzStorageBlobServiceProperty -ResourceGroupName $StateResourceGroupName -StorageAccountName $StateStorageAccountName -IsVersioningEnabled $true
$null = Enable-AzStorageBlobDeleteRetentionPolicy -ResourceGroupName $StateResourceGroupName -StorageAccountName $StateStorageAccountName -RetentionDays 30
$null = Enable-AzStorageContainerDeleteRetentionPolicy -ResourceGroupName $StateResourceGroupName -StorageAccountName $StateStorageAccountName -RetentionDays 30
if (-not (Get-AzRmStorageContainer -ResourceGroupName $StateResourceGroupName -StorageAccountName $StateStorageAccountName -Name $StateContainerName -ErrorAction Ignore)) {
	$null = New-AzRmStorageContainer -ResourceGroupName $StateResourceGroupName -StorageAccountName $StateStorageAccountName -Name $StateContainerName -PublicAccess None
}
Write-Host "  [ok] container $StateContainerName (versioning + soft delete on)"
#endregion

#region 5. Role assignments
Write-Host "`n[5/6] Role assignments for the service principal"
$roles = @{
	Contributor             = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
	UserAccessAdministrator = '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9'
	BlobDataContributor     = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
	Owner                   = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
	RbacAdministrator       = 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
}

# Terraform creates a custom role + role assignments for the Function App's Managed Identity.
# That needs Microsoft.Authorization/* - but the pipeline must never hand out privileged roles.
$privileged = "$($roles.Owner), $($roles.UserAccessAdministrator), $($roles.RbacAdministrator)"
$condition = @"
((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {$privileged}))
AND
((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {$privileged}))
"@
if ($SkipRoleAssignmentCondition) { $condition = $null }

$subscriptionScope = "/subscriptions/$SubscriptionId"
$saPath = (Get-AzStorageAccount -ResourceGroupName $StateResourceGroupName -Name $StateStorageAccountName).Id
Set-RoleAssignment -Scope $subscriptionScope -RoleDefinitionGuid $roles.Contributor -PrincipalId $sp.Id -RoleName 'Contributor'
Set-RoleAssignment -Scope $subscriptionScope -RoleDefinitionGuid $roles.UserAccessAdministrator -PrincipalId $sp.Id -RoleName 'User Access Administrator (constrained)' -Condition $condition
Set-RoleAssignment -Scope $saPath -RoleDefinitionGuid $roles.BlobDataContributor -PrincipalId $sp.Id -RoleName 'Storage Blob Data Contributor'
#endregion

#region 6. GitHub configuration
$variables = [ordered]@{
	AZURE_CLIENT_ID         = $app.AppId
	AZURE_TENANT_ID         = $tenantId
	AZURE_SUBSCRIPTION_ID   = $SubscriptionId
	TFSTATE_RESOURCE_GROUP  = $StateResourceGroupName
	TFSTATE_STORAGE_ACCOUNT = $StateStorageAccountName
	TFSTATE_CONTAINER       = $StateContainerName
}

Write-Host "`n[6/6] GitHub repository configuration"
if ($ConfigureGitHub) {
	if (-not (Get-Command gh -ErrorAction Ignore)) { throw 'GitHub CLI (gh) not found. Install it or run without -ConfigureGitHub.' }
	$null = gh api --method PUT "repos/$repoFullName/environments/$GitHubEnvironment"
	Write-Host "  [ok] environment '$GitHubEnvironment'"
	foreach ($entry in $variables.GetEnumerator()) {
		gh variable set $entry.Key --body $entry.Value --repo $repoFullName
		Write-Host "  [ok] variable $($entry.Key)"
	}
}
else {
	Write-Host "  Create the GitHub environment '$GitHubEnvironment' and these repository variables (Settings > Secrets and variables > Actions > Variables):"
	$variables.GetEnumerator() | ForEach-Object { Write-Host ("    {0,-24} {1}" -f $_.Key, $_.Value) }
}
#endregion

Write-Host "`nDone. No client secret was created - GitHub Actions signs in via OIDC."
[pscustomobject]$variables
