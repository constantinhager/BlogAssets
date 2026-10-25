function New-SrAppCertificate {
	<#
	.SYNOPSIS
		Creates a new certificate in the Key Vault and registers it on the app.

	.DESCRIPTION
		1. Create a self-signed certificate as a new version of app-<appId>-cert in the Key Vault.
		   The private key is generated in Key Vault.
		2. Read the current key credentials of the app, including their public keys.
		3. PATCH keyCredentials with all existing certificates plus the new one.
		   PATCH replaces the whole collection - a certificate missing in the body is deleted.
		4. If the PATCH fails, disable the new certificate version in Key Vault.

		Why PATCH and not addKey? addKey needs a proof-of-possession token signed with the private key
		of a certificate that is already valid on the app. Apps whose certificate already expired, or
		whose private key is somewhere else, can't use it. Microsoft documents PATCH as the way for those.

	.PARAMETER Decision
		The decision object from Get-SrCredentialDecision.

	.PARAMETER Config
		The configuration (Get-SrConfig).

	.EXAMPLE
		PS C:\> New-SrAppCertificate -Decision $decision -Config $config

		Renews the certificate of the app.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		$Decision,

		[Parameter(Mandatory = $true)]
		$Config
	)

	# Read the existing certificates first - if one of them comes back without its key, stop before creating anything
	$existing = Get-SrApplicationKeyCredential -AppObjectId $Decision.AppObjectId -TenantId $Decision.TenantId
	$missingKey = @($existing | Where-Object { -not $_.key })
	if ($missingKey.Count -gt 0) {
		throw "Graph returned $($missingKey.Count) key credential(s) without certificate data. Not updating keyCredentials, it would delete them."
	}

	$certificateName = Get-SrVaultObjectName -AppId $Decision.AppId -Kind Certificate
	$subjectName = ($Decision.DisplayName -replace '[^A-Za-z0-9 ._-]', '').Trim()
	if (-not $subjectName) { $subjectName = $Decision.AppId }
	if ($subjectName.Length -gt 64) { $subjectName = $subjectName.Substring(0, 64).Trim() }

	$vaultCertificate = New-SrKeyVaultCertificate -Name $certificateName -Subject "CN=$subjectName" `
		-ValidityMonths $Config.CertificateValidityMonths -Exportable $Config.CertificateExportable -Tags @{
		appId          = $Decision.AppId
		appObjectId    = $Decision.AppObjectId
		appDisplayName = $Decision.DisplayName
		tenantId       = $Decision.TenantId
		credentialType = 'Certificate'
		createdBy      = 'SecretRotation'
	}

	try {
		$x509 = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String($vaultCertificate.cer))
		$keyCredentials = [System.Collections.Generic.List[object]]::new()
		foreach ($credential in $existing) {
			$keyCredentials.Add(@{
					keyId               = $credential.keyId
					type                = $credential.type
					usage               = $credential.usage
					key                 = $credential.key
					displayName         = $credential.displayName
					customKeyIdentifier = $credential.customKeyIdentifier
					startDateTime       = ([DateTimeOffset]$credential.startDateTime).ToString('o')
					endDateTime         = ([DateTimeOffset]$credential.endDateTime).ToString('o')
				})
		}
		$newDisplayName = '{0} {1} {2}' -f $script:CredentialDisplayNamePrefix, [DateTime]::UtcNow.ToString('yyyy-MM-dd'), $x509.Thumbprint
		$keyCredentials.Add(@{
				type          = 'AsymmetricX509Cert'
				usage         = 'Verify'
				key           = $vaultCertificate.cer
				displayName   = $newDisplayName
				startDateTime = ([DateTimeOffset]$x509.NotBefore.ToUniversalTime()).ToString('o')
				endDateTime   = ([DateTimeOffset]$x509.NotAfter.ToUniversalTime()).ToString('o')
			})

		$uri = 'https://graph.microsoft.com/v1.0/applications/{0}' -f $Decision.AppObjectId
		$null = Invoke-SrRestRequest -Method PATCH -Uri $uri -Body @{ keyCredentials = $keyCredentials.ToArray() } -TenantId $Decision.TenantId
	}
	catch {
		$patchError = $_
		try {
			Disable-SrKeyVaultCertificateVersion -Id $vaultCertificate.id
			$rollback = 'The new certificate version was disabled in Key Vault.'
		}
		catch {
			$rollback = "Disabling the new certificate version ($($vaultCertificate.id)) failed too: $_"
		}
		throw "Could not register the new certificate on the app: $patchError $rollback"
	}

	[pscustomobject]@{
		Thumbprint    = $x509.Thumbprint
		StartDateTime = [DateTimeOffset]$x509.NotBefore.ToUniversalTime()
		EndDateTime   = [DateTimeOffset]$x509.NotAfter.ToUniversalTime()
		VaultObject   = $vaultCertificate.id
	}
}
