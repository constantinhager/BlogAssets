function Get-SrApplication {
	<#
	.SYNOPSIS
		Lists all app registrations of a tenant with their credentials.

	.DESCRIPTION
		Lists all app registrations of a tenant with their client secrets and certificates.
		The list call never contains the certificate data ('key' is null) - use
		Get-SrApplicationKeyCredential for that.

	.PARAMETER TenantId
		The tenant. Defaults to the home tenant.

	.EXAMPLE
		PS C:\> Get-SrApplication

		Lists all app registrations of the home tenant.
	#>
	[CmdletBinding()]
	param (
		[string]
		$TenantId
	)

	$uri = 'https://graph.microsoft.com/v1.0/applications?$select=id,appId,displayName,tags,passwordCredentials,keyCredentials&$top=999'
	Invoke-SrRestRequest -Uri $uri -TenantId $TenantId -All
}
