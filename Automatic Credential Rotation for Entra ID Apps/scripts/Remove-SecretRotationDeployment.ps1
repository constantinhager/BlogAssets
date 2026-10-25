#Requires -Modules Az.Accounts, Az.Resources
<#
.SYNOPSIS
	Removes the demo deployment: resource group, Exchange scope, pipeline identity and Terraform state.

.DESCRIPTION
	Counterpart of New-GitHubOidcDeploymentIdentity.ps1, Set-SecretRotationMailScope.ps1 and the Terraform deployment.
	Destructive - supports -WhatIf and asks before every step.

	With -GitHubOrganization and -GitHubRepository it also removes the GitHub repository variables
	(AZURE_*, TFSTATE_*) via gh. Other workflows in the same repository use the same variable names, so
	they are only removed while TFSTATE_RESOURCE_GROUP still points to this deployment's state. The
	environment 'production' is shared too - it is only removed with -RemoveGitHubEnvironment. The runs of
	the workflow (-WorkflowFileName) are removed with their logs and artifacts; runs in progress are kept.

	What stays:
	- The Key Vault is soft-deleted, not purged. With purge protection it can't be purged until the
	  retention period ends. That's on purpose: it holds the only copy of the renewed secrets.
	- Credentials the function created on app registrations. They expire on their own.
	- The rotation app, unless you use -RemoveRotationApp. Deleting it stops the function in every tenant
	  at once; the customer tenants keep an orphaned enterprise application they can delete.

.EXAMPLE
	PS C:\> ./scripts/Remove-SecretRotationDeployment.ps1 -ResourceGroupName rg-secrot-ab12c -RotationAppId $rotationAppId -Organization contoso.onmicrosoft.com -WhatIf

.EXAMPLE
	PS C:\> ./scripts/Remove-SecretRotationDeployment.ps1 -ResourceGroupName rg-secrot-ab12c -GitHubOrganization contoso -GitHubRepository BlogAssets -RemoveGitHubEnvironment

	Also removes the GitHub variables and the environment 'production'.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param (
	[Parameter(Mandatory = $true)]
	[string]
	$ResourceGroupName,

	[guid]
	$RotationAppId,

	[string]
	$Organization,

	[string]
	$ScopeName = 'SecretRotation Sender',

	[string]
	$AppDisplayName = 'github-entra-credential-rotation',

	[string]
	$StateResourceGroupName = 'rg-secrot-tfstate',

	[switch]
	$RemoveRotationApp,

	[string]
	$GitHubOrganization,

	[string]
	$GitHubRepository,

	[switch]
	$RemoveGitHubEnvironment,

	[string]
	$WorkflowFileName = 'entra-credential-rotation.yml'
)

$ErrorActionPreference = 'Stop'

if ($RotationAppId -and $Organization) {
	Connect-ExchangeOnline -Organization $Organization -ShowBanner:$false
	if ($PSCmdlet.ShouldProcess('Exchange Online', 'Remove role assignment, management scope and service principal')) {
		Get-ManagementRoleAssignment -Identity 'SecretRotation Application Mail.Send' -ErrorAction SilentlyContinue | Remove-ManagementRoleAssignment -Confirm:$false
		Get-ManagementScope -Identity $ScopeName -ErrorAction SilentlyContinue | Remove-ManagementScope -Confirm:$false
		Get-ServicePrincipal -Identity "$RotationAppId" -ErrorAction SilentlyContinue | Remove-ServicePrincipal -Confirm:$false
	}
}

if ((Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue) -and $PSCmdlet.ShouldProcess($ResourceGroupName, 'Remove resource group (Key Vault is soft-deleted)')) {
	Remove-AzResourceGroup -Name $ResourceGroupName -Force | Out-Null
}

$app = Get-AzADApplication -DisplayName $AppDisplayName | Select-Object -First 1
if ($app -and $PSCmdlet.ShouldProcess($AppDisplayName, 'Remove role assignments and pipeline app registration')) {
	$sp = Get-AzADServicePrincipal -ApplicationId $app.AppId
	if ($sp) { Get-AzRoleAssignment -ObjectId $sp.Id | Remove-AzRoleAssignment | Out-Null }
	Remove-AzADApplication -ObjectId $app.Id
}

if ($PSCmdlet.ShouldProcess($StateResourceGroupName, 'Remove Terraform state')) {
	Remove-AzResourceGroup -Name $StateResourceGroupName -Force -ErrorAction SilentlyContinue | Out-Null
}

if ($GitHubOrganization -and $GitHubRepository) {
	$repo = "$GitHubOrganization/$GitHubRepository"
	$variables = @(gh variable list --repo $repo --json name,value | ConvertFrom-Json)
	if ($LASTEXITCODE -ne 0) { throw "gh variable list failed for $repo." }
	$stateGroup = ($variables | Where-Object name -eq 'TFSTATE_RESOURCE_GROUP').value
	$present = @('AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'TFSTATE_RESOURCE_GROUP', 'TFSTATE_STORAGE_ACCOUNT', 'TFSTATE_CONTAINER' | Where-Object { $variables.name -contains $_ })
	if ($stateGroup -and $stateGroup -ne $StateResourceGroupName) {
		Write-Warning "GitHub variables of $repo kept: TFSTATE_RESOURCE_GROUP is '$stateGroup', not '$StateResourceGroupName' - another deployment owns them."
	}
	elseif ($present.Count -gt 0 -and $PSCmdlet.ShouldProcess($repo, "Remove GitHub variables $($present -join ', ')")) {
		foreach ($name in $present) {
			gh variable delete $name --repo $repo
			if ($LASTEXITCODE -ne 0) { throw "gh variable delete $name failed for $repo." }
		}
	}
	$environments = @(gh api "repos/$repo/environments" --jq '.environments[].name')
	if ($LASTEXITCODE -ne 0) { throw "Listing the environments of $repo failed." }
	if ($RemoveGitHubEnvironment -and $environments -contains 'production' -and $PSCmdlet.ShouldProcess("$repo environment 'production'", 'Remove GitHub environment')) {
		gh api --method DELETE "repos/$repo/environments/production"
		if ($LASTEXITCODE -ne 0) { throw "Removing the environment 'production' of $repo failed." }
	}

	$runs = @(gh api --paginate "repos/$repo/actions/workflows/$WorkflowFileName/runs?per_page=100" --jq '.workflow_runs[] | {id, status}' | ConvertFrom-Json)
	if ($LASTEXITCODE -ne 0) { Write-Warning "Listing the runs of $WorkflowFileName in $repo failed - runs kept." }
	elseif ($runs.Count -gt 0 -and $PSCmdlet.ShouldProcess("$repo $WorkflowFileName", "Remove $($runs.Count) workflow run(s) including logs and artifacts")) {
		foreach ($run in $runs) {
			if ($run.status -ne 'completed') { Write-Warning "Run $($run.id) is $($run.status) - kept."; continue }
			gh api --method DELETE "repos/$repo/actions/runs/$($run.id)" | Out-Null
			if ($LASTEXITCODE -ne 0) { Write-Warning "Removing run $($run.id) failed." }
		}
	}
}

if ($RemoveRotationApp -and $RotationAppId) {
	$rotationApp = Get-AzADApplication -ApplicationId $RotationAppId -ErrorAction SilentlyContinue
	if ($rotationApp -and $PSCmdlet.ShouldProcess($rotationApp.DisplayName, 'Remove rotation app registration (all tenants lose access)')) {
		Remove-AzADApplication -ObjectId $rotationApp.Id
	}
}
