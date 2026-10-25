function Backup-SrPublicCertificate {
	<#
	.SYNOPSIS
		Copies the public part of an app's existing certificates to the Key Vault.

	.DESCRIPTION
		Entra ID only stores the public key of a certificate credential. The private key never was in
		Entra ID, so it can't be backed up from there. What can be backed up is the public certificate:
		it shows which certificate an app trusts, and it lets you find the matching private key later.

		Each certificate is stored once as secret app-<appId>-pub-<thumbprint> (content type
		application/pkix-cert, Base64 DER). Certificates created by this function are skipped -
		they already live in Key Vault as certificate objects including their private key.

	.PARAMETER Application
		The application object from Graph.

	.PARAMETER TenantId
		The tenant of the application.

	.EXAMPLE
		PS C:\> Backup-SrPublicCertificate -Application $app -TenantId $tenantId

		Returns one object per certificate that was copied to Key Vault.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		$Application,

		[Parameter(Mandatory = $true)]
		[string]
		$TenantId
	)

	$candidates = @($Application.keyCredentials | Where-Object {
			$_ -and $_.type -eq 'AsymmetricX509Cert' -and "$($_.displayName)" -notlike "$($script:CredentialDisplayNamePrefix)*"
		})
	if ($candidates.Count -eq 0) { return }

	$keyCredentials = Get-SrApplicationKeyCredential -AppObjectId $Application.id -TenantId $TenantId
	foreach ($credential in $keyCredentials) {
		if ($credential.keyId -notin $candidates.keyId -or -not $credential.key) { continue }

		$x509 = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($credential.key))
		$name = Get-SrVaultObjectName -AppId $Application.appId -Kind PublicCertificate -Thumbprint $x509.Thumbprint
		if (Get-SrKeyVaultSecret -Name $name -MetadataOnly) { continue }

		$stored = Set-SrKeyVaultSecret -Name $name -Value $credential.key -ContentType 'application/pkix-cert' -Tags @{
			appId          = $Application.appId
			appObjectId    = $Application.id
			appDisplayName = $Application.displayName
			tenantId       = $TenantId
			keyId          = $credential.keyId
			thumbprint     = $x509.Thumbprint
			subject        = $x509.Subject
			notAfter       = ([DateTimeOffset]$x509.NotAfter.ToUniversalTime()).ToString('o')
			credentialType = 'PublicCertificate'
			createdBy      = 'SecretRotation'
		}

		[pscustomobject]@{
			AppId       = $Application.appId
			DisplayName = $Application.displayName
			Thumbprint  = $x509.Thumbprint
			VaultObject = $stored.Id
		}
	}
}
