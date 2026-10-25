function Get-SrApplicationKeyCredential {
	<#
	.SYNOPSIS
		Returns the key credentials of one app, including the certificate data.

	.DESCRIPTION
		Returns the key credentials of one app, including the certificate data ('key').
		Graph only returns 'key' for a single object with $select=keyCredentials.

	.PARAMETER AppObjectId
		Object ID of the application.

	.PARAMETER TenantId
		The tenant of the application.

	.EXAMPLE
		PS C:\> Get-SrApplicationKeyCredential -AppObjectId $app.id

		Returns the key credentials with their public certificates.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]
		$AppObjectId,

		[string]
		$TenantId
	)

	$uri = 'https://graph.microsoft.com/v1.0/applications/{0}?$select=keyCredentials' -f $AppObjectId
	@((Invoke-SrRestRequest -Uri $uri -TenantId $TenantId).keyCredentials | Where-Object { $_ })
}
