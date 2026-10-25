function Get-SrVaultObjectName {
	<#
	.SYNOPSIS
		Returns the Key Vault object name for a credential of an app.

	.DESCRIPTION
		Returns the Key Vault object name for a credential of an app.
		The app ID (client ID) is part of the name, because it never changes and is unique across tenants.
		The display name of the app is stored as a tag instead.

		app-<appId>-secret            client secret (secret, one version per renewal)
		app-<appId>-cert              certificate incl. private key (certificate, one version per renewal)
		app-<appId>-pub-<thumbprint>  public part of an existing certificate (secret)

	.PARAMETER AppId
		The application (client) ID.

	.PARAMETER Kind
		Secret, Certificate or PublicCertificate.

	.PARAMETER Thumbprint
		SHA-1 thumbprint (hex). Required for PublicCertificate.

	.EXAMPLE
		PS C:\> Get-SrVaultObjectName -AppId $appId -Kind Secret

		Returns app-<appId>-secret.
	#>
	[OutputType([string])]
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[guid]
		$AppId,

		[Parameter(Mandatory = $true)]
		[ValidateSet('Secret', 'Certificate', 'PublicCertificate')]
		[string]
		$Kind,

		[string]
		$Thumbprint
	)

	switch ($Kind) {
		'Secret' { 'app-{0}-secret' -f $AppId }
		'Certificate' { 'app-{0}-cert' -f $AppId }
		'PublicCertificate' {
			if ($Thumbprint -notmatch '^[0-9a-fA-F]{40}$') { throw "Invalid thumbprint '$Thumbprint'." }
			'app-{0}-pub-{1}' -f $AppId, $Thumbprint.ToLowerInvariant()
		}
	}
}
