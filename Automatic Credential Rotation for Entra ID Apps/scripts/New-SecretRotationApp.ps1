#Requires -Modules Microsoft.Graph.Applications
<#
.SYNOPSIS
	Creates the multi-tenant rotation app - the only identity the function uses for Microsoft Graph.

.DESCRIPTION
	Every Graph call of the function goes through this app, in the home tenant and in every customer
	tenant. The app has no secret and no certificate. Its federated identity credential trusts the
	user-assigned managed identity of the Function App (managed identity as FIC).

	The script is idempotent. Run it twice:

	1. Before the first deployment, without -ManagedIdentityPrincipalId:
	   - multi-tenant app registration, requesting Graph Application.ReadWrite.All
	   - service principal in the home tenant + admin consent (app role assignment) in the home tenant
	   - tag SecretRotation:Exclude, so the function never adds a credential to its own app
	   Put the printed app ID into production.tfvars (rotation_app_id) and deploy.

	2. After the deployment, with -ManagedIdentityPrincipalId (Terraform output managed_identity_principal_id):
	   - federated identity credential that trusts the managed identity

	Then an admin of every customer tenant opens the printed consent URL, and you add the tenant ID
	to customer_tenant_ids.

	Needs a Global Administrator or Privileged Role Administrator in the home tenant (admin consent for
	an application permission). That's why the GitHub pipeline doesn't do it.

.PARAMETER HomeTenantId
	The tenant of the managed identity and the app.

.PARAMETER ManagedIdentityPrincipalId
	Object (principal) ID of the user-assigned managed identity. Case-sensitive in the FIC subject.

.PARAMETER DisplayName
	Display name of the app registration.

.EXAMPLE
	PS C:\> ./scripts/New-SecretRotationApp.ps1 -HomeTenantId $tenantId

	Step 1: creates the app and consents in the home tenant.

.EXAMPLE
	PS C:\> ./scripts/New-SecretRotationApp.ps1 -HomeTenantId $tenantId -ManagedIdentityPrincipalId (terraform -chdir=infra output -raw managed_identity_principal_id)

	Step 2: adds the federated identity credential.
#>
[CmdletBinding(SupportsShouldProcess)]
param (
	[Parameter(Mandatory = $true)]
	[guid]
	$HomeTenantId,

	[string]
	$ManagedIdentityPrincipalId,

	[string]
	$DisplayName = 'Entra Credential Rotation'
)

$ErrorActionPreference = 'Stop'
Connect-MgGraph -TenantId $HomeTenantId -Scopes 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All' -NoWelcome

$graphAppId = '00000003-0000-0000-c000-000000000000'
$graph = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"
$role = $graph.AppRoles | Where-Object { $_.Value -eq 'Application.ReadWrite.All' -and $_.AllowedMemberTypes -contains 'Application' }

# 1. App registration (multi-tenant, no credentials)
$app = Get-MgApplication -Filter "displayName eq '$DisplayName'"
if (@($app).Count -gt 1) { throw "More than one app named '$DisplayName'." }
if (-not $app -and $PSCmdlet.ShouldProcess($DisplayName, 'Create multi-tenant app registration')) {
	$app = New-MgApplication -DisplayName $DisplayName -SignInAudience 'AzureADMultipleOrgs' -Tags @('SecretRotation:Exclude') -RequiredResourceAccess @(
		@{ ResourceAppId = $graphAppId; ResourceAccess = @(@{ Id = $role.Id; Type = 'Role' }) }
	)
}

# 2. Service principal + admin consent in the home tenant
$sp = Get-MgServicePrincipal -Filter "appId eq '$($app.AppId)'"
if (-not $sp -and $PSCmdlet.ShouldProcess($DisplayName, 'Create service principal in the home tenant')) {
	$sp = New-MgServicePrincipal -AppId $app.AppId
}
$granted = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -All |
	Where-Object { $_.AppRoleId -eq $role.Id -and $_.ResourceId -eq $graph.Id }
if (-not $granted -and $PSCmdlet.ShouldProcess($DisplayName, 'Admin consent: Microsoft Graph Application.ReadWrite.All (home tenant)')) {
	$null = New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -PrincipalId $sp.Id -ResourceId $graph.Id -AppRoleId $role.Id
}

# 3. Federated identity credential for the managed identity
if ($ManagedIdentityPrincipalId) {
	$fic = Get-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id | Where-Object { $_.Subject -ceq $ManagedIdentityPrincipalId }
	if (-not $fic -and $PSCmdlet.ShouldProcess($DisplayName, "Federated identity credential for managed identity $ManagedIdentityPrincipalId")) {
		$null = New-MgApplicationFederatedIdentityCredential -ApplicationId $app.Id -BodyParameter @{
			name        = 'secret-rotation-function'
			issuer      = "https://login.microsoftonline.com/$HomeTenantId/v2.0"
			subject     = $ManagedIdentityPrincipalId
			audiences   = @('api://AzureADTokenExchange')
			description = 'User-assigned managed identity of the credential rotation Function App'
		}
	}
}
else {
	Write-Warning 'No -ManagedIdentityPrincipalId: the federated identity credential is missing. Run the script again after the deployment.'
}

[pscustomobject]@{
	RotationAppId             = $app.AppId    # rotation_app_id / SR_ROTATION_APP_ID, -RotationAppId of Set-SecretRotationMailScope.ps1
	HomeServicePrincipalId    = $sp.Id        # -RotationServicePrincipalId of Set-SecretRotationMailScope.ps1
	CustomerConsentUrl        = "https://login.microsoftonline.com/<customer-tenant-id>/adminconsent?client_id=$($app.AppId)"
}
