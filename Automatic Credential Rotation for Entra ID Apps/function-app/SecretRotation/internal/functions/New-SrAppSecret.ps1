function New-SrAppSecret {
	<#
	.SYNOPSIS
		Adds a new client secret to an app and stores it in the Key Vault.

	.DESCRIPTION
		1. addPassword on the application. Entra ID generates the secret; the value is only returned once.
		2. Write the value as a new version of the Key Vault secret app-<appId>-secret.
		3. If the Key Vault write fails, remove the new credential again (removePassword).
		   A secret that exists in Entra ID but nowhere else is useless and only adds attack surface.

		Old secrets stay on the app. The applications switch to the new version in their own time,
		and the old secret simply expires.

	.PARAMETER Decision
		The decision object from Get-SrCredentialDecision.

	.PARAMETER Config
		The configuration (Get-SrConfig).

	.EXAMPLE
		PS C:\> New-SrAppSecret -Decision $decision -Config $config

		Renews the client secret of the app.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		$Decision,

		[Parameter(Mandatory = $true)]
		$Config
	)

	$graphBase = 'https://graph.microsoft.com/v1.0/applications/{0}' -f $Decision.AppObjectId
	$start = [DateTimeOffset]::UtcNow
	$body = @{
		passwordCredential = @{
			displayName   = '{0} {1}' -f $script:CredentialDisplayNamePrefix, $start.ToString('yyyy-MM-dd')
			startDateTime = $start.ToString('o')
			endDateTime   = $start.AddDays($Config.SecretValidityDays).ToString('o')
		}
	}
	$credential = Invoke-SrRestRequest -Method POST -Uri "$graphBase/addPassword" -Body $body -TenantId $Decision.TenantId

	$secretName = Get-SrVaultObjectName -AppId $Decision.AppId -Kind Secret
	try {
		$stored = Set-SrKeyVaultSecret -Name $secretName -Value $credential.secretText -ContentType 'text/plain' `
			-NotBefore ([DateTimeOffset]$credential.startDateTime) -Expires ([DateTimeOffset]$credential.endDateTime) -Tags @{
			appId          = $Decision.AppId
			appObjectId    = $Decision.AppObjectId
			appDisplayName = $Decision.DisplayName
			tenantId       = $Decision.TenantId
			keyId          = $credential.keyId
			credentialType = 'ClientSecret'
			createdBy      = 'SecretRotation'
		}
	}
	catch {
		$storeError = $_
		try {
			$null = Invoke-SrRestRequest -Method POST -Uri "$graphBase/removePassword" -Body @{ keyId = $credential.keyId } -TenantId $Decision.TenantId
			$rollback = 'The new secret was removed from the app again.'
		}
		catch {
			$rollback = "Removing the new secret ($($credential.keyId)) failed too: $_ - remove it manually."
		}
		throw "Could not store the new secret in Key Vault: $storeError $rollback"
	}
	finally {
		$credential.secretText = $null
	}

	[pscustomobject]@{
		KeyId         = $credential.keyId
		Hint          = $credential.hint
		StartDateTime = [DateTimeOffset]$credential.startDateTime
		EndDateTime   = [DateTimeOffset]$credential.endDateTime
		VaultObject   = $stored.Id
	}
}
