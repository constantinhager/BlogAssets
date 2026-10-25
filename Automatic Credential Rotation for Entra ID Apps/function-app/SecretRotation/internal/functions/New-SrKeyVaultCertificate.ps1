function New-SrKeyVaultCertificate {
	<#
	.SYNOPSIS
		Creates a self-signed certificate (new version) in the Key Vault.

	.DESCRIPTION
		Creates a self-signed certificate in the Key Vault and waits until it is issued.
		The private key is generated inside Key Vault and never leaves it during this process.

		The policy sets an explicit lifetime action (EmailContacts), so Key Vault does not renew
		the certificate on its own. Renewal is the job of this function app, because a new
		certificate version is useless until its public key is registered on the app.

	.PARAMETER Name
		Name of the certificate.

	.PARAMETER Subject
		Subject of the certificate, e.g. 'CN=My App'.

	.PARAMETER ValidityMonths
		Validity in months.

	.PARAMETER Exportable
		Whether the private key is exportable (needed if an app downloads the PFX from Key Vault).

	.PARAMETER Tags
		Tags of the certificate.

	.PARAMETER TimeoutSeconds
		How long to wait for the certificate to be issued.

	.EXAMPLE
		PS C:\> New-SrKeyVaultCertificate -Name 'app-...-cert' -Subject 'CN=My App' -ValidityMonths 12

		Creates the certificate and returns the issued certificate bundle.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]
		$Name,

		[Parameter(Mandatory = $true)]
		[string]
		$Subject,

		[int]
		$ValidityMonths = 12,

		[bool]
		$Exportable = $true,

		[hashtable]
		$Tags = @{},

		[int]
		$TimeoutSeconds = 120
	)

	$config = Get-SrConfig
	$baseUri = 'https://{0}.vault.azure.net/certificates/{1}' -f $config.KeyVaultName, $Name

	$body = @{
		policy     = @{
			key_props        = @{
				exportable = $Exportable
				kty        = 'RSA'
				key_size   = 2048
				reuse_key  = $false
			}
			secret_props     = @{ contentType = 'application/x-pkcs12' }
			x509_props       = @{
				subject         = $Subject
				validity_months = $ValidityMonths
				key_usage       = @('digitalSignature', 'keyEncipherment')
			}
			issuer           = @{ name = 'Self' }
			lifetime_actions = @(
				@{
					trigger = @{ days_before_expiry = 30 }
					action  = @{ action_type = 'EmailContacts' }
				}
			)
		}
		attributes = @{ enabled = $true }
		tags       = ConvertTo-SrVaultTag -Tags $Tags
	}
	$operation = Invoke-SrRestRequest -Method POST -Uri ('{0}/create?api-version={1}' -f $baseUri, $script:KeyVaultApiVersion) -Body $body

	$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
	while ($operation.status -eq 'inProgress') {
		if ([DateTime]::UtcNow -gt $deadline) {
			throw "Certificate '$Name' was not issued within $TimeoutSeconds seconds."
		}
		Start-Sleep -Seconds 2
		$operation = Invoke-SrRestRequest -Uri ('{0}/pending?api-version={1}' -f $baseUri, $script:KeyVaultApiVersion)
	}
	if ($operation.status -ne 'completed') {
		throw "Certificate '$Name' failed: $($operation.status) $($operation.status_details) $($operation.error.message)"
	}

	Invoke-SrRestRequest -Uri ('{0}?api-version={1}' -f $baseUri, $script:KeyVaultApiVersion)
}
