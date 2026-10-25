function Get-SrConfig {
	<#
	.SYNOPSIS
		Reads the configuration of the function app from the SR_* app settings.

	.DESCRIPTION
		Reads the configuration of the function app from the SR_* app settings (environment variables).
		The result is cached for the lifetime of the worker. Use -Refresh to read the settings again.

	.PARAMETER Refresh
		Ignore the cached configuration and read the app settings again.

	.EXAMPLE
		PS C:\> $config = Get-SrConfig

		Returns the current configuration.
	#>
	[OutputType([pscustomobject])]
	[CmdletBinding()]
	param (
		[switch]
		$Refresh
	)

	if ($script:SrConfig -and -not $Refresh) { return $script:SrConfig }

	$homeTenantId = Get-SrEnvValue -Name 'SR_HOME_TENANT_ID' -Mandatory
	$customerTenantIds = @(Get-SrEnvValue -Name 'SR_CUSTOMER_TENANT_IDS' -AsList | Where-Object { $_ -ne $homeTenantId })

	$script:SrConfig = [pscustomobject]@{
		HomeTenantId              = $homeTenantId
		ManagedIdentityClientId   = Get-SrEnvValue -Name 'SR_MANAGED_IDENTITY_CLIENT_ID'
		KeyVaultName              = Get-SrEnvValue -Name 'SR_KEYVAULT_NAME' -Mandatory

		# Renewal state table (Azure Table Storage). Admins set RenewalState = Renewable to approve a renewal.
		StateStorageAccount       = Get-SrEnvValue -Name 'SR_STATE_STORAGE_ACCOUNT' -Mandatory
		StateTable                = Get-SrEnvValue -Name 'SR_STATE_TABLE' -Default 'CredentialRenewals'

		# Every Graph call - home tenant and customer tenants - goes through this multi-tenant app.
		# It has no secret: its federated identity credential trusts the user-assigned managed identity.
		RotationAppId             = Get-SrEnvValue -Name 'SR_ROTATION_APP_ID' -Mandatory
		CustomerTenantIds         = $customerTenantIds
		TenantIds                 = @($homeTenantId) + $customerTenantIds

		# When to renew and how long the new credential lives
		ThresholdDays             = [int](Get-SrEnvValue -Name 'SR_THRESHOLD_DAYS' -Default 30)
		ExpiredGraceDays          = [int](Get-SrEnvValue -Name 'SR_EXPIRED_GRACE_DAYS' -Default 7)
		SecretValidityDays        = [int](Get-SrEnvValue -Name 'SR_SECRET_VALIDITY_DAYS' -Default 180)
		CertificateValidityMonths = [int](Get-SrEnvValue -Name 'SR_CERT_VALIDITY_MONTHS' -Default 12)
		CertificateExportable     = Get-SrEnvValue -Name 'SR_CERT_EXPORTABLE' -Default 'true' -AsBool

		# Apps with this tag are only reported, never offered for renewal (renewal on request needs Force)
		ExcludeTag                = Get-SrEnvValue -Name 'SR_EXCLUDE_TAG' -Default 'SecretRotation:Exclude'

		BackupPublicCertificates  = Get-SrEnvValue -Name 'SR_BACKUP_PUBLIC_CERTS' -Default 'true' -AsBool

		# Notifications
		MailSender                = Get-SrEnvValue -Name 'SR_MAIL_SENDER'
		MailRecipients            = @(Get-SrEnvValue -Name 'SR_MAIL_RECIPIENTS' -AsList)

	}

	if ($script:SrConfig.RotationAppId -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
		throw "SR_ROTATION_APP_ID must be the client ID (GUID) of the multi-tenant rotation app, not '$($script:SrConfig.RotationAppId)'."
	}
	if ($script:SrConfig.StateStorageAccount -notmatch '^[a-z0-9]{3,24}$') {
		throw "SR_STATE_STORAGE_ACCOUNT must be a storage account name, not '$($script:SrConfig.StateStorageAccount)'."
	}
	if ($script:SrConfig.StateTable -notmatch '^[A-Za-z][A-Za-z0-9]{2,62}$') {
		throw "SR_STATE_TABLE must be a table name, not '$($script:SrConfig.StateTable)'."
	}
	if ($script:SrConfig.SecretValidityDays -lt 1 -or $script:SrConfig.CertificateValidityMonths -lt 1) {
		throw 'SR_SECRET_VALIDITY_DAYS and SR_CERT_VALIDITY_MONTHS must be 1 or higher.'
	}

	$script:SrConfig
}
