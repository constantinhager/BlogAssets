#Requires -Modules Az.Accounts, Az.Resources
<#
.SYNOPSIS
	Removes the demo deployment: resource group, Exchange scope, pipeline identity and Terraform state.

.DESCRIPTION
	Counterpart of New-GitHubOidcDeploymentIdentity.ps1, Set-SecretRotationMailScope.ps1 and the Terraform deployment.
	Destructive - supports -WhatIf and asks before every step.

	What stays:
	- The Key Vault is soft-deleted, not purged. With purge protection it can't be purged until the
	  retention period ends. That's on purpose: it holds the only copy of the renewed secrets.
	- Credentials the function created on app registrations. They expire on their own.
	- The rotation app, unless you use -RemoveRotationApp. Deleting it stops the function in every tenant
	  at once; the customer tenants keep an orphaned enterprise application they can delete.

.EXAMPLE
	PS C:\> ./scripts/Remove-SecretRotationDeployment.ps1 -ResourceGroupName rg-secrot-ab12c -RotationAppId $rotationAppId -Organization contoso.onmicrosoft.com -WhatIf
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
	$RemoveRotationApp
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

if ($PSCmdlet.ShouldProcess($ResourceGroupName, 'Remove resource group (Key Vault is soft-deleted)')) {
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

if ($RemoveRotationApp -and $RotationAppId) {
	$rotationApp = Get-AzADApplication -ApplicationId $RotationAppId -ErrorAction SilentlyContinue
	if ($rotationApp -and $PSCmdlet.ShouldProcess($rotationApp.DisplayName, 'Remove rotation app registration (all tenants lose access)')) {
		Remove-AzADApplication -ObjectId $rotationApp.Id
	}
}
