function Disable-SrKeyVaultCertificateVersion {
	<#
	.SYNOPSIS
		Disables one version of a Key Vault certificate.

	.DESCRIPTION
		Disables one version of a Key Vault certificate.
		Used when a new certificate could not be registered on the app: an enabled version that
		Entra ID doesn't know would break every client that always loads the latest version.

	.PARAMETER Id
		The full ID of the certificate version (https://<vault>.vault.azure.net/certificates/<name>/<version>).

	.EXAMPLE
		PS C:\> Disable-SrKeyVaultCertificateVersion -Id $certificate.id

		Disables this certificate version.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]
		$Id
	)

	$uri = '{0}?api-version={1}' -f $Id, $script:KeyVaultApiVersion
	$null = Invoke-SrRestRequest -Method PATCH -Uri $uri -Body @{ attributes = @{ enabled = $false } }
}
