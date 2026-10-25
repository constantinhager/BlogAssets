#Requires -Modules Az.Accounts, Az.Resources, Az.Storage
<#
.SYNOPSIS
	One-time bootstrap: the identity GitHub Actions uses to deploy, with federated credentials instead of a secret.

.DESCRIPTION
	Creates:
	1. an app registration + service principal for the pipeline
	2. federated credentials for the main branch, pull requests and the GitHub environment 'production'
	3. the resource provider registrations
	4. a Terraform state storage account (Entra ID auth only, versioning, soft delete)
	5. role assignments:
	   - Contributor on the subscription
	   - Storage Blob Data Contributor on the state account
	   - Role Based Access Control Administrator with a condition: it may ONLY assign or remove
	     Key Vault Secrets Officer, Key Vault Certificates Officer and Storage Table Data Contributor
	6. optionally (-ConfigureGitHub) the GitHub environment and repository variables via gh

	No client secret is created. The repository only stores IDs as variables.

	The pipeline does NOT get any Graph or Entra ID permission. The rotation app (incl. admin consent)
	and the Exchange scope are set up by an admin with New-SecretRotationApp.ps1 and
	Set-SecretRotationMailScope.ps1.

.PARAMETER GitHubOrganization
	GitHub organization or user.

.PARAMETER GitHubRepository
	Repository name.

.PARAMETER Location
	Region of the state storage account.

.PARAMETER ResolveGitHubId
	Use the immutable IDs (org@id/repo@id) in the subject claim. Needed if the repository uses
	immutable subject claims - otherwise azure/login fails with AADSTS700213.

.PARAMETER ConfigureGitHub
	Create the environment 'production' and the repository variables with the GitHub CLI.

.EXAMPLE
	PS C:\> Connect-AzAccount
	PS C:\> ./scripts/New-GitHubOidcDeploymentIdentity.ps1 -GitHubOrganization contoso -GitHubRepository BlogAssets -ConfigureGitHub
#>
[CmdletBinding(SupportsShouldProcess)]
param (
	[Parameter(Mandatory = $true)]
	[string]
	$GitHubOrganization,

	[Parameter(Mandatory = $true)]
	[string]
	$GitHubRepository,

	[string]
	$Location = 'germanywestcentral',

	[string]
	$AppDisplayName = 'github-entra-credential-rotation',

	[string]
	$StateResourceGroupName = 'rg-secrot-tfstate',

	[switch]
	$ResolveGitHubId,

	[switch]
	$ConfigureGitHub
)

$ErrorActionPreference = 'Stop'
$context = Get-AzContext
if (-not $context) { throw 'Run Connect-AzAccount first.' }
$subscriptionId = $context.Subscription.Id
$tenantId = $context.Tenant.Id
$subscriptionScope = "/subscriptions/$subscriptionId"

function Add-RoleAssignmentOnce {
	[CmdletBinding(SupportsShouldProcess)]
	param ($ObjectId, $RoleName, $Scope, $Condition)
	$existing = Get-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $RoleName -Scope $Scope -ErrorAction SilentlyContinue |
		Where-Object Scope -eq $Scope
	if ($existing) { Write-Host "  $RoleName on $Scope exists."; return }
	if (-not $PSCmdlet.ShouldProcess($Scope, "Assign $RoleName")) { return }

	$param = @{ ObjectId = $ObjectId; RoleDefinitionName = $RoleName; Scope = $Scope; ObjectType = 'ServicePrincipal' }
	if ($Condition) { $param.Condition = $Condition; $param.ConditionVersion = '2.0' }
	for ($i = 1; $i -le 10; $i++) {
		try { $null = New-AzRoleAssignment @param; Write-Host "  $RoleName on $Scope assigned."; return }
		catch {
			# A new service principal needs a moment to replicate
			if ("$_" -notmatch 'PrincipalNotFound|does not exist in the directory' -or $i -eq 10) { throw }
			Start-Sleep -Seconds 10
		}
	}
}

# 1. App registration + service principal
$app = Get-AzADApplication -DisplayName $AppDisplayName | Select-Object -First 1
if (-not $app -and $PSCmdlet.ShouldProcess($AppDisplayName, 'Create app registration')) {
	$app = New-AzADApplication -DisplayName $AppDisplayName
}
$sp = Get-AzADServicePrincipal -ApplicationId $app.AppId
if (-not $sp -and $PSCmdlet.ShouldProcess($AppDisplayName, 'Create service principal')) {
	$sp = New-AzADServicePrincipal -ApplicationId $app.AppId
}

# 2. Federated credentials
$repoClaim = '{0}/{1}' -f $GitHubOrganization, $GitHubRepository
if ($ResolveGitHubId) {
	$repoInfo = gh api "repos/$GitHubOrganization/$GitHubRepository" | ConvertFrom-Json
	$repoClaim = '{0}@{1}/{2}@{3}' -f $GitHubOrganization, $repoInfo.owner.id, $GitHubRepository, $repoInfo.id
}
$subjects = [ordered]@{
	'github-main'     = "repo:$($repoClaim):ref:refs/heads/main"
	'github-pr'       = "repo:$($repoClaim):pull_request"
	'github-env-prod' = "repo:$($repoClaim):environment:production"
}
$existingFics = @(Get-AzADAppFederatedCredential -ApplicationObjectId $app.Id)
foreach ($name in $subjects.Keys) {
	$subject = $subjects[$name]
	$fic = $existingFics | Where-Object Name -eq $name
	if ($fic -and $fic.Subject -eq $subject) { Write-Host "  Federated credential $name exists."; continue }
	if (-not $PSCmdlet.ShouldProcess($subject, "Federated credential $name")) { continue }
	if ($fic) { Update-AzADAppFederatedCredential -ApplicationObjectId $app.Id -FederatedCredentialId $fic.Id -Subject $subject; continue }
	$null = New-AzADAppFederatedCredential -ApplicationObjectId $app.Id -Name $name -Issuer 'https://token.actions.githubusercontent.com' `
		-Subject $subject -Audience 'api://AzureADTokenExchange'
}

# 3. Resource providers
foreach ($provider in 'Microsoft.Web', 'Microsoft.KeyVault', 'Microsoft.Storage', 'Microsoft.ManagedIdentity', 'Microsoft.OperationalInsights', 'Microsoft.Insights') {
	if ((Get-AzResourceProvider -ProviderNamespace $provider).RegistrationState -contains 'Registered') { continue }
	if ($PSCmdlet.ShouldProcess($provider, 'Register resource provider')) { $null = Register-AzResourceProvider -ProviderNamespace $provider }
}

# 4. Terraform state
if (-not (Get-AzResourceGroup -Name $StateResourceGroupName -ErrorAction SilentlyContinue) -and $PSCmdlet.ShouldProcess($StateResourceGroupName, 'Create resource group')) {
	$null = New-AzResourceGroup -Name $StateResourceGroupName -Location $Location
}
$stateAccount = Get-AzStorageAccount -ResourceGroupName $StateResourceGroupName -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $stateAccount -and $PSCmdlet.ShouldProcess($StateResourceGroupName, 'Create state storage account')) {
	$accountName = 'stsecrottf{0}' -f (-join ((97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ }))
	$stateAccount = New-AzStorageAccount -ResourceGroupName $StateResourceGroupName -Name $accountName -Location $Location `
		-SkuName Standard_LRS -Kind StorageV2 -MinimumTlsVersion TLS1_2 -AllowBlobPublicAccess $false -AllowSharedKeyAccess $false
	$null = Update-AzStorageBlobServiceProperty -ResourceGroupName $StateResourceGroupName -StorageAccountName $accountName -IsVersioningEnabled $true
	$null = Enable-AzStorageBlobDeleteRetentionPolicy -ResourceGroupName $StateResourceGroupName -StorageAccountName $accountName -RetentionDays 14
	$null = New-AzRmStorageContainer -ResourceGroupName $StateResourceGroupName -StorageAccountName $accountName -Name 'tfstate'
}

# 5. Role assignments
$kvSecretsOfficer = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
$kvCertificatesOfficer = 'a4417e6f-fecd-4de8-b567-7b0420556985'
$tableDataContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
$condition = @"
((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$kvSecretsOfficer, $kvCertificatesOfficer, $tableDataContributor}))
AND
((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$kvSecretsOfficer, $kvCertificatesOfficer, $tableDataContributor}))
"@
Add-RoleAssignmentOnce -ObjectId $sp.Id -RoleName 'Contributor' -Scope $subscriptionScope
Add-RoleAssignmentOnce -ObjectId $sp.Id -RoleName 'Storage Blob Data Contributor' -Scope $stateAccount.Id
Add-RoleAssignmentOnce -ObjectId $sp.Id -RoleName 'Role Based Access Control Administrator' -Scope $subscriptionScope -Condition $condition

# 6. GitHub
$variables = [ordered]@{
	AZURE_CLIENT_ID         = $app.AppId
	AZURE_TENANT_ID         = $tenantId
	AZURE_SUBSCRIPTION_ID   = $subscriptionId
	TFSTATE_RESOURCE_GROUP  = $StateResourceGroupName
	TFSTATE_STORAGE_ACCOUNT = $stateAccount.StorageAccountName
	TFSTATE_CONTAINER       = 'tfstate'
}
if ($ConfigureGitHub -and $PSCmdlet.ShouldProcess("$GitHubOrganization/$GitHubRepository", 'Set environment and variables')) {
	gh api --method PUT "repos/$GitHubOrganization/$GitHubRepository/environments/production" | Out-Null
	foreach ($key in $variables.Keys) { gh variable set $key --body $variables[$key] --repo "$GitHubOrganization/$GitHubRepository" }
}
[pscustomobject]$variables
