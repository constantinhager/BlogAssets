function Get-AumConfig {
	<#
	.SYNOPSIS
		Returns the Function App configuration from the app settings.

	.DESCRIPTION
		All settings are plain app settings (environment variables), set by Terraform:

		AUM_SUBSCRIPTION_IDS         Comma separated list of subscriptions the functions work on by default.
		AUM_DEFAULT_LOCATION         Default Azure region for new maintenance configurations.
		AUM_MAINTENANCE_RG           Default resource group for new maintenance configurations.
		AUM_EXCLUSION_STORAGE_ACCOUNT Storage account that holds the exclusion table.
		AUM_EXCLUSION_TABLE          Name of the table with the excluded KBs.

	.EXAMPLE
		PS C:\> $config = Get-AumConfig

		Reads the current configuration.
	#>
	[OutputType([pscustomobject])]
	[CmdletBinding()]
	param ()

	[pscustomobject]@{
		SubscriptionIds        = @($env:AUM_SUBSCRIPTION_IDS -split ',' | ForEach-Object Trim | Where-Object { $_ })
		DefaultLocation        = $env:AUM_DEFAULT_LOCATION
		MaintenanceRg          = $env:AUM_MAINTENANCE_RG
		ExclusionStorageAccount = $env:AUM_EXCLUSION_STORAGE_ACCOUNT
		ExclusionTable         = $(if ($env:AUM_EXCLUSION_TABLE) { $env:AUM_EXCLUSION_TABLE } else { 'UpdateExclusions' })
	}
}
