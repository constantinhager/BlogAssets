function Get-UpdateMaintenanceConfiguration {
	<#
	.SYNOPSIS
		Lists the maintenance configurations (scheduled patching) in the configured subscriptions.

	.DESCRIPTION
		Calls GET /subscriptions/{id}/providers/Microsoft.Maintenance/maintenanceConfigurations
		for each subscription and returns a flat summary per configuration,
		including its dynamic scopes (subscription-level configuration assignments).

		By default only 'InGuestPatch' configurations (Azure Update Manager) are returned.

		Published as HTTP endpoint: /api/Get-UpdateMaintenanceConfiguration

	.PARAMETER Name
		Optional name filter. Wildcards are allowed, e.g. 'mc-wave*'.

	.PARAMETER MaintenanceScope
		InGuestPatch (default) or All.

	.PARAMETER SubscriptionId
		Optional list of subscriptions. Defaults to the AUM_SUBSCRIPTION_IDS app setting.

	.EXAMPLE
		GET /api/Get-UpdateMaintenanceConfiguration

		Lists all Azure Update Manager schedules.

	.EXAMPLE
		GET /api/Get-UpdateMaintenanceConfiguration?Name=mc-wave*

		Lists all schedules whose name starts with 'mc-wave'.
	#>
	[CmdletBinding()]
	param (
		[string]
		$Name = '*',

		[ValidateSet('InGuestPatch', 'All')]
		[string]
		$MaintenanceScope = 'InGuestPatch',

		[string[]]
		$SubscriptionId
	)

	$subscriptions = @(ConvertTo-AumStringArray -InputObject $SubscriptionId)
	if (-not $subscriptions) { $subscriptions = (Get-AumConfig).SubscriptionIds }
	if (-not $subscriptions) { throw 'No subscription specified and AUM_SUBSCRIPTION_IDS is empty.' }

	foreach ($subscription in $subscriptions) {
		$configurations = Invoke-AumArmRequest -Path "/subscriptions/$subscription/providers/Microsoft.Maintenance/maintenanceConfigurations" -ApiVersion $script:ApiVersion.Maintenance -All

		# Dynamic scopes live as configuration assignments on subscription level.
		# Azure does not support listing them via ARM (404 NotImplemented), but Resource Graph exposes them.
		# 'filter' is a reserved KQL keyword, so the property is read with bracket notation.
		$assignments = @()
		try {
			$assignmentQuery = "maintenanceresources | where type =~ 'microsoft.maintenance/configurationassignments' | project id, name, maintenanceConfigurationId = tostring(properties.maintenanceConfigurationId), scopeFilter = properties['filter']"
			$assignments = @(Search-AumResourceGraph -Query $assignmentQuery -SubscriptionId $subscription)
		}
		catch { Write-Warning "Could not list configuration assignments in $($subscription): $_" }

		foreach ($configuration in $configurations) {
			$properties = $configuration.properties
			if ($MaintenanceScope -ne 'All' -and $properties.maintenanceScope -ne 'InGuestPatch') { continue }
			if ($configuration.name -notlike $Name) { continue }

			$scopes = foreach ($assignment in $assignments) {
				if ($assignment.maintenanceConfigurationId -ne $configuration.id) { continue }
				$tagSettings = $assignment.scopeFilter.tagSettings.tags
				$tagText = if ($tagSettings) {
					($tagSettings.PSObject.Properties | ForEach-Object { '{0}={1}' -f $_.Name, ($_.Value -join '|') }) -join '; '
				}
				'{0} [{1}]' -f $assignment.name, $tagText
			}

			[pscustomobject]@{
				Name               = $configuration.name
				ResourceGroup      = ($configuration.id -split '/')[4]
				Subscription       = $subscription
				Location           = $configuration.location
				MaintenanceScope   = $properties.maintenanceScope
				StartDateTime      = $properties.maintenanceWindow.startDateTime
				ExpirationDateTime = $properties.maintenanceWindow.expirationDateTime
				Duration           = $properties.maintenanceWindow.duration
				TimeZone           = $properties.maintenanceWindow.timeZone
				RecurEvery         = $properties.maintenanceWindow.recurEvery
				RebootSetting      = $properties.installPatches.rebootSetting
				WindowsClasses     = @($properties.installPatches.windowsParameters.classificationsToInclude) -join ', '
				LinuxClasses       = @($properties.installPatches.linuxParameters.classificationsToInclude) -join ', '
				ExcludedKbs        = @($properties.installPatches.windowsParameters.kbNumbersToExclude) -join ', '
				DynamicScopes      = @($scopes) -join ' | '
				Id                 = $configuration.id
			}
		}
	}
}
