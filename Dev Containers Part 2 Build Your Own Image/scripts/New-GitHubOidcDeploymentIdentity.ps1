<#
.SYNOPSIS
	Pre-provisions everything GitHub Actions needs to build the dev container image and to deploy
	the Azure Container Registry with Terraform - without any secret.

.DESCRIPTION
	Run this once, before the first workflow run. It creates (idempotent, safe to re-run):

	1. Resource provider registrations: Microsoft.ContainerRegistry, Microsoft.Storage
	2. Two resource groups:
	   - the workload resource group for the registry (Terraform deploys INTO it)
	   - the resource group for the Terraform state
	3. A storage account + container for the Terraform state (Entra ID auth only, no shared keys)
	4. The registry name (checked for global availability, not created - Terraform creates the registry)
	5. Two Entra ID app registrations + service principals, each with federated credentials (OIDC):
	   - infra identity (Terraform)
	       repo:<org>/<repo>:ref:refs/heads/main          plan on pushes to main
	       repo:<org>/<repo>:pull_request                 plan on pull requests
	       repo:<org>/<repo>:environment:<env>            apply
	   - image identity (docker push)
	       repo:<org>/<repo>:ref:refs/heads/main          push on main, schedule, manual run

	   If the repository uses immutable IDs in the OIDC subject claim, pass -GitHubOrganizationId and
	   -GitHubRepositoryId, or let the script look them up with the GitHub CLI (-ResolveGitHubId).
	   The subjects then look like repo:<org>@<orgId>/<repo>@<repoId>:pull_request.

	   Optional (-AcrPullGroupName): an Entra ID security group for the people who pull the image.
	   Its object ID is added to ACR_PULL_PRINCIPAL_IDS, so Terraform assigns AcrPull to it.
	   The signed-in user and the principals in -AcrPullGroupMember become members of the group.
	6. Role assignments for the infra identity - scoped to the workload resource group, not the subscription:
	   - Contributor                                on the workload resource group
	   - Role Based Access Control Administrator    on the workload resource group, constrained by a
	                                                condition: it may ONLY assign AcrPull and AcrPush
	   - Storage Blob Data Contributor              on the state container
	   The image identity gets nothing here. Terraform gives it AcrPush on the registry.
	7. Optional (-ConfigureGitHub): GitHub repository variables + the GitHub environment via the gh CLI.

	All Azure and Entra ID calls use the Az PowerShell modules (Az.Accounts, Az.Resources, Az.Storage).
	Sign in first with Connect-AzAccount.

	Required rights of the person running the script:
	- Entra ID: Application Developer (or Application Administrator) to create the apps
	- Entra ID (only with -AcrPullGroupName): permission to create security groups - allowed for all
	  members by default, otherwise Groups Administrator. To add members to a group that already exists,
	  you must own it or be Groups Administrator.
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
	passing them. The GitHub CLI must be installed and signed in (gh auth login).

.PARAMETER SubscriptionId
	Target subscription. Defaults to the current Az context subscription.

.PARAMETER Location
	Region for both resource groups, the state storage account and (through the resource group) the registry.

.PARAMETER ResourceGroupName
	Workload resource group. Terraform deploys the registry into it.

.PARAMETER RegistryName
	Globally unique name of the container registry (5-50 alphanumeric characters).
	Defaults to the registry that already exists in the workload resource group, then to the
	ACR_NAME repository variable, then to 'acrdevcontainer' + 6 random characters.

.PARAMETER StateResourceGroupName
	Resource group for the Terraform state.

.PARAMETER StateStorageAccountName
	Name of the state storage account. Defaults to 'sttfstate' + 6 random characters.

.PARAMETER StateContainerName
	Blob container for the state file.

.PARAMETER InfraAppDisplayName
	Display name of the app registration that runs Terraform.

.PARAMETER ImageAppDisplayName
	Display name of the app registration that pushes the image.

.PARAMETER GitHubEnvironment
	Name of the GitHub environment used by the Terraform apply job.

.PARAMETER AcrPullPrincipalId
	Object IDs of Entra ID groups or users that may pull the image. Written to the repository
	variable ACR_PULL_PRINCIPAL_IDS - Terraform assigns AcrPull to them.

.PARAMETER AcrPullGroupName
	Display name of an Entra ID security group for the people who pull the image. The script creates
	the group if it does not exist yet and adds its object ID to the AcrPull principals.
	The signed-in user is added as a member (skipped when signed in as a service principal).
	Remove-DevContainerRegistryDeployment.ps1 -AcrPullGroupName deletes the group again.

.PARAMETER AcrPullGroupMember
	User principal names (user@contoso.com) or object IDs of users, groups or service principals to add
	to the AcrPull group. Members that are already in the group are skipped. Requires -AcrPullGroupName.

.PARAMETER ConfigureGitHub
	Write the IDs as repository variables and create the environment with the GitHub CLI (gh).

.EXAMPLE
	PS C:\> Connect-AzAccount
	PS C:\> $identity = @{
		GitHubOrganization = 'contoso'
		GitHubRepository   = 'BlogAssets'
		ConfigureGitHub    = $true
	}
	PS C:\> ./New-GitHubOidcDeploymentIdentity.ps1 @identity

	Creates both identities, the resource groups and the state storage, and configures the GitHub repository.

.EXAMPLE
	PS C:\> $identity = @{
		GitHubOrganization = 'contoso'
		GitHubRepository   = 'BlogAssets'
		RegistryName       = 'acrcontosodevcontainers'
		AcrPullPrincipalId = '11111111-1111-1111-1111-111111111111'
		ResolveGitHubId    = $true
		ConfigureGitHub    = $true
	}
	PS C:\> ./New-GitHubOidcDeploymentIdentity.ps1 @identity

	Uses a fixed registry name, lets the Entra ID group 11111111-... pull the image, and creates the
	federated credentials with immutable-ID subjects.

.EXAMPLE
	PS C:\> $identity = @{
		GitHubOrganization = 'contoso'
		GitHubRepository   = 'BlogAssets'
		AcrPullGroupName   = 'grp-devcontainer-acrpull'
		AcrPullGroupMember = @(
			'alice@contoso.com'
			'bob@contoso.com'
		)
		ConfigureGitHub    = $true
	}
	PS C:\> ./New-GitHubOidcDeploymentIdentity.ps1 @identity

	Creates the security group grp-devcontainer-acrpull (or reuses it), adds the signed-in user, Alice and
	Bob, and writes its object ID to ACR_PULL_PRINCIPAL_IDS. Terraform then gives the group AcrPull on the registry.

.EXAMPLE
	PS C:\> $identity = @{
		GitHubOrganization = 'contoso'
		GitHubRepository   = 'BlogAssets'
		SubscriptionId     = '00000000-0000-0000-0000-000000000000'
		Location           = 'westeurope'
	}
	PS C:\> ./New-GitHubOidcDeploymentIdentity.ps1 @identity

	Uses a specific subscription and region. The GitHub environment and repository variables are not
	written; the script prints the values instead.
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
	[string]
	$Location = 'germanywestcentral',

	[Parameter()]
	[ValidateLength(1, 90)]
	[string]
	$ResourceGroupName = 'rg-devcontainer-registry',

	[Parameter()]
	[ValidatePattern('^[a-zA-Z0-9]{5,50}$', ErrorMessage = "'{0}' is not a valid registry name (5-50 alphanumeric characters).")]
	[string]
	$RegistryName,

	[Parameter()]
	[ValidateLength(1, 90)]
	[string]
	$StateResourceGroupName = 'rg-devcontainer-tfstate',

	[Parameter()]
	[ValidatePattern('^[a-z0-9]{3,24}$')]
	[string]
	$StateStorageAccountName,

	[Parameter()]
	[ValidatePattern('^[a-z0-9](?:[a-z0-9]|-(?!-)){1,61}[a-z0-9]$', ErrorMessage = "'{0}' is not a valid blob container name (3-63 lowercase letters, digits, single hyphens).")]
	[string]
	$StateContainerName = 'tfstate',

	[Parameter()]
	[ValidateLength(1, 120)]
	[string]
	$InfraAppDisplayName = "github-oidc-$GitHubRepository-devcontainer-infra",

	[Parameter()]
	[ValidateLength(1, 120)]
	[string]
	$ImageAppDisplayName = "github-oidc-$GitHubRepository-devcontainer-image",

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]
	$GitHubEnvironment = 'devcontainer-registry',

	[Parameter()]
	[ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$', ErrorMessage = "'{0}' is not a valid object ID (GUID).")]
	[string[]]
	$AcrPullPrincipalId = @(),

	[Parameter()]
	[ValidateLength(1, 256)]
	[string]
	$AcrPullGroupName,

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string[]]
	$AcrPullGroupMember = @(),

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

	.PARAMETER Scope
		Resource ID of the scope, for example a resource group or a storage container resource ID.

	.PARAMETER RoleDefinitionGuid
		GUID of the built-in or custom role definition.

	.PARAMETER PrincipalId
		Object ID of the service principal that receives the role.

	.PARAMETER RoleName
		Display name of the role. Only used for the progress output.

	.PARAMETER Description
		Description of the role assignment.

	.PARAMETER Condition
		Optional ABAC condition that restricts the assignment.

	.EXAMPLE
		PS C:\> $assignment = @{
			Scope              = $resourceGroup.ResourceId
			RoleDefinitionGuid = $roles.Contributor
			PrincipalId        = $infraSp.Id
			RoleName           = 'Contributor'
			Description        = 'Terraform deploys the registry'
		}
		PS C:\> Set-RoleAssignment @assignment

		Assigns Contributor on the resource group, unless it is already assigned there.
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

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]
		$Description,

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
		Description      = $Description
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

function Set-GitHubOidcApplication {
	<#
	.SYNOPSIS
		Creates (or reuses) an app registration + service principal with federated credentials for GitHub Actions.

	.DESCRIPTION
		Idempotent. A credential with the same name but another subject is updated, so a re-run with
		-ResolveGitHubId fixes the subjects of an earlier run. No client secret is created.

	.PARAMETER DisplayName
		Display name of the app registration.

	.PARAMETER Credential
		Hashtables with name, subject and description of each federated credential.

	.PARAMETER Description
		Description of the app registration.

	.EXAMPLE
		PS C:\> $app = @{
			DisplayName = 'github-oidc-BlogAssets-devcontainer-image'
			Description = 'Pushes the dev container image'
			Credential  = @(
				@{ name = 'github-branch-main'; subject = 'repo:contoso/BlogAssets:ref:refs/heads/main'; description = 'Pushes to main' }
			)
		}
		PS C:\> Set-GitHubOidcApplication @app

		Returns an object with the properties App and ServicePrincipal.
	#>
	[CmdletBinding()]
	[OutputType([pscustomobject])]
	param (
		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]
		$DisplayName,

		[Parameter(Mandatory)]
		[hashtable[]]
		$Credential,

		[Parameter(Mandatory)]
		[ValidateNotNullOrEmpty()]
		[string]
		$Description
	)

	$app = Get-AzADApplication -DisplayName $DisplayName | Where-Object DisplayName -eq $DisplayName | Select-Object -First 1
	if (-not $app) {
		$app = New-AzADApplication -DisplayName $DisplayName -SignInAudience 'AzureADMyOrg' -Description $Description
		Write-Host "  [new] app $DisplayName (appId $($app.AppId))"
	}
	else { Write-Host "  [ok] app $DisplayName (appId $($app.AppId), exists)" }

	$sp = Get-AzADServicePrincipal -ApplicationId $app.AppId
	if (-not $sp) {
		$sp = New-AzADServicePrincipal -ApplicationId $app.AppId
		Write-Host "  [new] service principal $($sp.Id)"
	}
	else { Write-Host "  [ok] service principal $($sp.Id) (exists)" }

	$existing = @(Get-AzADAppFederatedCredential -ApplicationObjectId $app.Id)
	foreach ($entry in $Credential) {
		$sameName = $existing | Where-Object Name -eq $entry.name | Select-Object -First 1
		if ($sameName -and $sameName.Subject -eq $entry.subject) {
			Write-Host "  [ok] $($entry.subject) (exists)"
			continue
		}
		if ($sameName) {
			# Credential names are unique per app: fix the subject of the existing one instead of creating a duplicate
			$null = Update-AzADAppFederatedCredential -ApplicationObjectId $app.Id -FederatedCredentialId $sameName.Id -Subject $entry.subject
			Write-Host "  [update] $($entry.name): $($sameName.Subject) -> $($entry.subject)"
			continue
		}
		if ($existing.Subject -contains $entry.subject) {
			Write-Host "  [ok] $($entry.subject) (exists under another name)"
			continue
		}
		$federatedCredential = @{
			ApplicationObjectId = $app.Id
			Name                = $entry.name
			Issuer              = 'https://token.actions.githubusercontent.com'
			Subject             = $entry.subject
			Audience            = 'api://AzureADTokenExchange'
			Description         = $entry.description
		}
		$null = New-AzADAppFederatedCredential @federatedCredential
		Write-Host "  [new] $($entry.subject)"
	}

	[pscustomobject]@{
		App              = $app
		ServicePrincipal = $sp
	}
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
if ($AcrPullGroupMember -and -not $AcrPullGroupName) {
	throw '-AcrPullGroupMember needs -AcrPullGroupName.'
}
if (($ResolveGitHubId -or $ConfigureGitHub) -and -not (Get-Command gh -ErrorAction Ignore)) {
	throw 'GitHub CLI (gh) not found. Install it, or run without -ResolveGitHubId / -ConfigureGitHub.'
}
if ($ResolveGitHubId) {
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

#region 1. Resource providers
Write-Host "`n[1/7] Resource provider registrations"
# The deployment identity only has rights on one resource group and can't register providers itself.
foreach ($provider in 'Microsoft.ContainerRegistry', 'Microsoft.Storage') {
	$null = Register-AzResourceProvider -ProviderNamespace $provider
	for ($attempt = 1; $attempt -le 30; $attempt++) {
		$state = (Get-AzResourceProvider -ProviderNamespace $provider | Select-Object -First 1).RegistrationState
		if ($state -eq 'Registered') { break }
		Start-Sleep -Seconds 10
	}
	Write-Host "  [ok] $provider ($state)"
}
#endregion

#region 2. Resource groups
Write-Host "`n[2/7] Resource groups"
$workloadGroup = New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag @{ purpose = 'devcontainer-images' } -Force
Write-Host "  [ok] $ResourceGroupName (registry)"
$null = New-AzResourceGroup -Name $StateResourceGroupName -Location $Location -Tag @{ purpose = 'terraform-state' } -Force
Write-Host "  [ok] $StateResourceGroupName (Terraform state)"
#endregion

#region 3. Terraform state storage
Write-Host "`n[3/7] Terraform state storage"
# Re-use an existing state account in the resource group, if there is one
$accounts = @(Get-AzStorageAccount -ResourceGroupName $StateResourceGroupName)
if ($accounts -and -not $PSBoundParameters.ContainsKey('StateStorageAccountName')) {
	$StateStorageAccountName = $accounts[0].StorageAccountName
}

if (-not ($accounts | Where-Object StorageAccountName -eq $StateStorageAccountName)) {
	$storageAccount = @{
		ResourceGroupName      = $StateResourceGroupName
		Name                   = $StateStorageAccountName
		Location               = $Location
		SkuName                = 'Standard_LRS'
		Kind                   = 'StorageV2'
		Tag                    = @{ purpose = 'terraform-state' }
		MinimumTlsVersion      = 'TLS1_2'
		AllowBlobPublicAccess  = $false
		AllowSharedKeyAccess   = $false
		EnableHttpsTrafficOnly = $true
	}
	$null = New-AzStorageAccount @storageAccount
	Write-Host "  [new] storage account $StateStorageAccountName"
}
else { Write-Host "  [ok] storage account $StateStorageAccountName (exists)" }

# Entra ID only - the backend uses use_azuread_auth. The container is managed through ARM,
# so no shared key or data-plane role is needed for this script.
$null = Update-AzStorageBlobServiceProperty -ResourceGroupName $StateResourceGroupName -StorageAccountName $StateStorageAccountName -IsVersioningEnabled $true
$null = Enable-AzStorageBlobDeleteRetentionPolicy -ResourceGroupName $StateResourceGroupName -StorageAccountName $StateStorageAccountName -RetentionDays 30
$null = Enable-AzStorageContainerDeleteRetentionPolicy -ResourceGroupName $StateResourceGroupName -StorageAccountName $StateStorageAccountName -RetentionDays 30
if (-not (Get-AzRmStorageContainer -ResourceGroupName $StateResourceGroupName -StorageAccountName $StateStorageAccountName -Name $StateContainerName -ErrorAction Ignore)) {
	$null = New-AzRmStorageContainer -ResourceGroupName $StateResourceGroupName -StorageAccountName $StateStorageAccountName -Name $StateContainerName -PublicAccess None
}
Write-Host "  [ok] container $StateContainerName (versioning + soft delete on)"
#endregion

#region 4. Registry name
Write-Host "`n[4/7] Registry name"
$existingRegistry = Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.ContainerRegistry/registries' | Select-Object -First 1
if (-not $RegistryName -and $existingRegistry) {
	$RegistryName = $existingRegistry.Name
}
if (-not $RegistryName -and $ConfigureGitHub) {
	# Keep the name of an earlier run, before Terraform created the registry
	$previousName = gh variable get ACR_NAME --repo $repoFullName 2>$null
	if ($LASTEXITCODE -eq 0 -and $previousName) { $RegistryName = "$previousName".Trim() }
}
if (-not $RegistryName) {
	$RegistryName = 'acrdevcontainer' + -join ((97..122) + (48..57) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
}

if ($existingRegistry -and $existingRegistry.Name -eq $RegistryName) {
	Write-Host "  [ok] $RegistryName (exists in $ResourceGroupName)"
}
else {
	# Registry names are global (<name>.azurecr.io). Check before Terraform fails on it.
	$check = @{
		Method  = 'POST'
		Path    = "/subscriptions/$SubscriptionId/providers/Microsoft.ContainerRegistry/checkNameAvailability?api-version=2023-07-01"
		Payload = @{ name = $RegistryName; type = 'Microsoft.ContainerRegistry/registries' } | ConvertTo-Json -Compress
	}
	$response = Invoke-AzRestMethod @check
	if ($response.StatusCode -ne 200) { throw "Name check for '$RegistryName' failed: $($response.StatusCode) $($response.Content)" }
	$availability = $response.Content | ConvertFrom-Json
	if (-not $availability.nameAvailable) { throw "Registry name '$RegistryName' is not available: $($availability.message) Pass another -RegistryName." }
	Write-Host "  [ok] $RegistryName (available - Terraform creates it)"
}
#endregion

#region 5. Identities + federated credentials
Write-Host "`n[5/7] Identities"
Write-Host "  Infra identity (Terraform)"
$infraApp = @{
	DisplayName = $InfraAppDisplayName
	Description = "GitHub Actions OIDC identity for $repoFullName - Terraform for the dev container registry. Created by New-GitHubOidcDeploymentIdentity.ps1"
	Credential  = @(
		@{ name = 'github-branch-main'; subject = "$($repoSubject):ref:refs/heads/main"; description = 'Pushes to main (terraform plan)' }
		@{ name = 'github-pull-request'; subject = "$($repoSubject):pull_request"; description = 'Pull requests (terraform plan)' }
		@{ name = "github-env-$GitHubEnvironment"; subject = "$($repoSubject):environment:$GitHubEnvironment"; description = "GitHub environment '$GitHubEnvironment' (terraform apply)" }
	)
}
$infra = Set-GitHubOidcApplication @infraApp

Write-Host "  Image identity (docker push)"
$imageApp = @{
	DisplayName = $ImageAppDisplayName
	Description = "GitHub Actions OIDC identity for $repoFullName - pushes the dev container image. Created by New-GitHubOidcDeploymentIdentity.ps1"
	Credential  = @(
		@{ name = 'github-branch-main'; subject = "$($repoSubject):ref:refs/heads/main"; description = 'Pushes to main, schedule and manual runs (docker push)' }
	)
}
$image = Set-GitHubOidcApplication @imageApp

if ($AcrPullGroupName) {
	Write-Host "  Pull group (AcrPull)"
	$pullGroup = @(Get-AzADGroup -DisplayName $AcrPullGroupName | Where-Object DisplayName -eq $AcrPullGroupName)
	if ($pullGroup.Count -gt 1) {
		throw "More than one group is named '$AcrPullGroupName'. Pass its object ID with -AcrPullPrincipalId instead."
	}
	if ($pullGroup) {
		$pullGroup = $pullGroup[0]
		Write-Host "  [ok] group $AcrPullGroupName ($($pullGroup.Id), exists)"
	} else {
		# The mail nickname is required by Entra ID, even for a group without mail
		$mailNickname = ($AcrPullGroupName -replace '[^A-Za-z0-9._-]', '')
		if (-not $mailNickname) {
			$mailNickname = 'acrpull' + -join ((97..122) + (48..57) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
		}
		$group = @{
			DisplayName     = $AcrPullGroupName
			MailNickname    = $mailNickname.Substring(0, [Math]::Min(64, $mailNickname.Length))
			Description     = "May pull the dev container image of $repoFullName (AcrPull). Created by New-GitHubOidcDeploymentIdentity.ps1"
			SecurityEnabled = $true
			MailEnabled     = $false
		}
		$pullGroup = New-AzADGroup @group
		Write-Host "  [new] group $AcrPullGroupName ($($pullGroup.Id))"
	}

	# Members: the signed-in user (to test the pull right away) plus -AcrPullGroupMember
	$memberIds = [System.Collections.Generic.List[string]]::new()
	try {
		$signedInUser = Get-AzADUser -SignedIn
	} catch {
		$signedInUser = $null
	}
	if ($signedInUser) {
		$memberIds.Add($signedInUser.Id)
	} else {
		Write-Host "  ... signed in as a service principal - not added to the group"
	}
	foreach ($member in $AcrPullGroupMember) {
		if ($member -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
			$memberIds.Add($member)
			continue
		}
		$user = Get-AzADUser -UserPrincipalName $member -ErrorAction Ignore
		if (-not $user) {
			throw "User '$member' not found in Entra ID. Pass a user principal name or an object ID."
		}
		$memberIds.Add($user.Id)
	}

	$existingMemberIds = @(Get-AzADGroupMember -GroupObjectId $pullGroup.Id | ForEach-Object Id)
	foreach ($memberId in $memberIds | Select-Object -Unique) {
		if ($existingMemberIds -contains $memberId) {
			Write-Host "  [ok] member $memberId (exists)"
			continue
		}
		Add-AzADGroupMember -TargetGroupObjectId $pullGroup.Id -MemberObjectId $memberId
		Write-Host "  [new] member $memberId"
	}
	if ($AcrPullPrincipalId -notcontains $pullGroup.Id) {
		$AcrPullPrincipalId = @($AcrPullPrincipalId) + $pullGroup.Id
	}
}
#endregion

#region 6. Role assignments
Write-Host "`n[6/7] Role assignments for the infra identity"
$roles = @{
	Contributor         = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
	RbacAdministrator   = 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
	BlobDataContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
	AcrPull             = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
	AcrPush             = '8311e382-0749-4cb8-b61a-304f252e45ec'
}

# Terraform assigns AcrPush (image identity) and AcrPull (team). Nothing else.
# The condition allows writing and deleting role assignments for exactly these two roles.
$allowedRoles = "$($roles.AcrPull), $($roles.AcrPush)"
$condition = @"
((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$allowedRoles}))
AND
((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$allowedRoles}))
"@

$stateAccountId = (Get-AzStorageAccount -ResourceGroupName $StateResourceGroupName -Name $StateStorageAccountName).Id
$stateContainerScope = "$stateAccountId/blobServices/default/containers/$StateContainerName"
$description = "GitHub Actions (Terraform) for $repoFullName - dev container registry"

Set-RoleAssignment -Scope $workloadGroup.ResourceId -RoleDefinitionGuid $roles.Contributor -PrincipalId $infra.ServicePrincipal.Id -RoleName 'Contributor' -Description $description
Set-RoleAssignment -Scope $workloadGroup.ResourceId -RoleDefinitionGuid $roles.RbacAdministrator -PrincipalId $infra.ServicePrincipal.Id -RoleName 'Role Based Access Control Administrator (AcrPull/AcrPush only)' -Description $description -Condition $condition
Set-RoleAssignment -Scope $stateContainerScope -RoleDefinitionGuid $roles.BlobDataContributor -PrincipalId $infra.ServicePrincipal.Id -RoleName 'Storage Blob Data Contributor' -Description $description
#endregion

#region 7. GitHub configuration
$variables = [ordered]@{
	AZURE_TENANT_ID         = $tenantId
	AZURE_SUBSCRIPTION_ID   = $SubscriptionId
	AZURE_INFRA_CLIENT_ID         = $infra.App.AppId
	AZURE_IMAGE_CLIENT_ID         = $image.App.AppId
	AZURE_IMAGE_PRINCIPAL_ID      = $image.ServicePrincipal.Id
	AZURE_RESOURCE_GROUP          = $ResourceGroupName
	ACR_NAME                = $RegistryName
	ACR_PULL_PRINCIPAL_IDS  = ConvertTo-Json -InputObject @($AcrPullPrincipalId) -Compress
	TFSTATE_RESOURCE_GROUP  = $StateResourceGroupName
	TFSTATE_STORAGE_ACCOUNT = $StateStorageAccountName
	TFSTATE_CONTAINER       = $StateContainerName
}

Write-Host "`n[7/7] GitHub repository configuration"
if ($ConfigureGitHub) {
	$null = gh api --method PUT "repos/$repoFullName/environments/$GitHubEnvironment"
	if ($LASTEXITCODE -ne 0) { throw "Could not create the environment '$GitHubEnvironment' in $repoFullName." }
	Write-Host "  [ok] environment '$GitHubEnvironment'"
	foreach ($entry in $variables.GetEnumerator()) {
		gh variable set $entry.Key --body $entry.Value --repo $repoFullName
		if ($LASTEXITCODE -ne 0) { throw "Could not set the variable $($entry.Key) in $repoFullName." }
		Write-Host "  [ok] variable $($entry.Key)"
	}
}
else {
	Write-Host "  Create the GitHub environment '$GitHubEnvironment' and these repository variables (Settings > Secrets and variables > Actions > Variables):"
	$variables.GetEnumerator() | ForEach-Object { Write-Host ("    {0,-37} {1}" -f $_.Key, $_.Value) }
}
#endregion

Write-Host "`nDone. No client secret was created - GitHub Actions signs in via OIDC."
Write-Host 'Next: run the workflow "Dev Containers Part 2" (Actions > Run workflow). It deploys the registry, then builds and pushes the image.'
[pscustomobject]$variables
