function New-UpdateMaintenanceConfiguration {
	<#
	.SYNOPSIS
		Creates (or updates) an Azure Update Manager maintenance configuration (scheduled patching).

	.DESCRIPTION
		Creates a maintenance configuration with scope 'InGuestPatch' via
		PUT .../providers/Microsoft.Maintenance/maintenanceConfigurations/{name}.

		Optional:
		- ExclusionScope pulls the excluded KBs from the exclusion table ('Global' + the given scope).
		- TagName / TagValue add a dynamic scope, so every machine with that tag
		  is patched by this schedule (one assignment per subscription).

		Machines need patch orchestration 'Customer Managed Schedules'
		(patchMode AutomaticByPlatform + bypassPlatformSafetyChecksOnUserSchedule = true).

		Published as HTTP endpoint: /api/New-UpdateMaintenanceConfiguration

	.PARAMETER Name
		Name of the maintenance configuration.

	.PARAMETER StartDateTime
		First start of the window, format 'yyyy-MM-dd HH:mm' in the given time zone.

	.PARAMETER RecurEvery
		Recurrence, e.g. 'Day', '1Week Saturday', 'Month Second Tuesday Offset4' (Patch Tuesday + 4 days).

	.PARAMETER Duration
		Length of the window, 'HH:mm', between 01:30 and 03:55. Defaults to 03:55.

	.PARAMETER TimeZone
		Windows time zone name. Defaults to 'W. Europe Standard Time'.

	.PARAMETER ExpirationDateTime
		Optional end of the schedule, format 'yyyy-MM-dd HH:mm'.

	.PARAMETER RebootSetting
		IfRequired (default), Never or Always.

	.PARAMETER Classification
		Windows classifications. Defaults to Critical, Security.

	.PARAMETER LinuxClassification
		Linux classifications. Defaults to Critical, Security.

	.PARAMETER ExcludedKb
		KBs to exclude in this schedule.

	.PARAMETER ExclusionScope
		If set, the KBs from the exclusion table (partition 'Global' + this scope) are excluded too.

	.PARAMETER TagName
		Optional: tag name for a dynamic scope.

	.PARAMETER TagValue
		Optional: tag value for a dynamic scope.

	.PARAMETER ResourceGroupName
		Resource group for the configuration. Defaults to AUM_MAINTENANCE_RG.

	.PARAMETER SubscriptionId
		Subscription for the configuration. Defaults to the first entry of AUM_SUBSCRIPTION_IDS.

	.PARAMETER DynamicScopeSubscriptionId
		Subscriptions the dynamic scope covers. Defaults to AUM_SUBSCRIPTION_IDS.

	.PARAMETER Location
		Region of the configuration. Defaults to AUM_DEFAULT_LOCATION.

	.EXAMPLE
		POST /api/New-UpdateMaintenanceConfiguration
		{
		  "Name": "mc-wave1-saturday",
		  "StartDateTime": "2026-10-10 22:00",
		  "RecurEvery": "1Week Saturday",
		  "ExclusionScope": "Wave1",
		  "TagName": "UpdateGroup",
		  "TagValue": "Wave1"
		}

		Patches every machine tagged UpdateGroup=Wave1 every Saturday at 22:00,
		minus the KBs from the exclusion table.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[ValidatePattern('^[A-Za-z0-9][A-Za-z0-9_.-]{0,126}[A-Za-z0-9_]$')]
		[string]
		$Name,

		[Parameter(Mandatory = $true)]
		[ValidatePattern('^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$')]
		[string]
		$StartDateTime,

		[Parameter(Mandatory = $true)]
		[string]
		$RecurEvery,

		[ValidatePattern('^\d{2}:\d{2}$')]
		[string]
		$Duration = '03:55',

		[string]
		$TimeZone = 'W. Europe Standard Time',

		[ValidatePattern('^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$')]
		[string]
		$ExpirationDateTime,

		[ValidateSet('IfRequired', 'Never', 'Always')]
		[string]
		$RebootSetting = 'IfRequired',

		[string[]]
		$Classification = @('Critical', 'Security'),

		[string[]]
		$LinuxClassification = @('Critical', 'Security'),

		[string[]]
		$ExcludedKb,

		[string]
		$ExclusionScope,

		[string]
		$TagName,

		[string]
		$TagValue,

		[string]
		$ResourceGroupName,

		[string]
		$SubscriptionId,

		[string[]]
		$DynamicScopeSubscriptionId,

		[string]
		$Location
	)

	$config = Get-AumConfig
	if (-not $ResourceGroupName) { $ResourceGroupName = $config.MaintenanceRg }
	if (-not $SubscriptionId) { $SubscriptionId = @($config.SubscriptionIds)[0] }
	if (-not $Location) { $Location = $config.DefaultLocation }
	if (-not ($ResourceGroupName -and $SubscriptionId -and $Location)) {
		throw 'ResourceGroupName, SubscriptionId and Location are required (no defaults configured).'
	}

	$durationSpan = [timespan]::ParseExact($Duration, 'hh\:mm', $null)
	if ($durationSpan -lt [timespan]'01:30' -or $durationSpan -gt [timespan]'03:55') {
		throw "Duration must be between 01:30 and 03:55 (got $Duration)."
	}
	if (($TagName -and -not $TagValue) -or ($TagValue -and -not $TagName)) {
		throw 'TagName and TagValue must be used together.'
	}

	# Exclusions: explicit list + table
	$kbList = @(ConvertTo-AumStringArray -InputObject $ExcludedKb)
	if ($ExclusionScope) { $kbList += @(Get-AumExcludedKb -Scope $ExclusionScope).Kb }
	$excludedKbs = @(ConvertTo-AumKbNumber -Kb $kbList)

	$maintenanceWindow = [ordered]@{
		startDateTime = $StartDateTime
		duration      = $Duration
		timeZone      = $TimeZone
		recurEvery    = $RecurEvery
	}
	if ($ExpirationDateTime) { $maintenanceWindow.expirationDateTime = $ExpirationDateTime }

	$body = @{
		location   = $Location
		properties = @{
			namespace           = 'Microsoft.Maintenance'
			maintenanceScope    = 'InGuestPatch'
			visibility          = 'Custom'
			extensionProperties = @{ InGuestPatchMode = 'User' }
			maintenanceWindow   = $maintenanceWindow
			installPatches      = @{
				rebootSetting     = $RebootSetting
				windowsParameters = @{
					classificationsToInclude = @(ConvertTo-AumStringArray -InputObject $Classification)
					kbNumbersToExclude       = @($excludedKbs)
				}
				linuxParameters   = @{
					classificationsToInclude = @(ConvertTo-AumStringArray -InputObject $LinuxClassification)
				}
			}
		}
	}

	$configPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Maintenance/maintenanceConfigurations/$Name"
	$response = Invoke-AumArmRequest -Method PUT -Path $configPath -ApiVersion $script:ApiVersion.Maintenance -Body $body
	$configId = $response.Content.id
	Write-Host "New-UpdateMaintenanceConfiguration: $configId ($($response.StatusCode))"

	# Optional dynamic scope: one subscription-level assignment per subscription
	$dynamicScopes = @()
	if ($TagName) {
		$scopeSubscriptions = @(ConvertTo-AumStringArray -InputObject $DynamicScopeSubscriptionId)
		if (-not $scopeSubscriptions) { $scopeSubscriptions = $config.SubscriptionIds }
		if (-not $scopeSubscriptions) { $scopeSubscriptions = @($SubscriptionId) }

		$assignmentName = ('{0}-{1}-{2}' -f $Name, $TagName, $TagValue) -replace '[^A-Za-z0-9_.-]', '-'
		$dynamicScopes = foreach ($scopeSubscription in $scopeSubscriptions) {
			$assignmentBody = @{
				properties = @{
					maintenanceConfigurationId = $configId
					filter                     = @{
						resourceTypes = @('Microsoft.Compute/virtualMachines', 'Microsoft.HybridCompute/machines')
						tagSettings   = @{
							tags           = @{ $TagName = @($TagValue) }
							filterOperator = 'Any'
						}
					}
				}
			}
			$assignmentPath = "/subscriptions/$scopeSubscription/providers/Microsoft.Maintenance/configurationAssignments/$assignmentName"
			$null = Invoke-AumArmRequest -Method PUT -Path $assignmentPath -ApiVersion $script:ApiVersion.Maintenance -Body $assignmentBody
			[pscustomobject]@{
				Subscription = $scopeSubscription
				Assignment   = $assignmentName
				Filter       = "$TagName=$TagValue"
			}
		}
	}

	[pscustomobject]@{
		Name          = $Name
		Id            = $configId
		Location      = $Location
		StartDateTime = $StartDateTime
		Duration      = $Duration
		TimeZone      = $TimeZone
		RecurEvery    = $RecurEvery
		RebootSetting = $RebootSetting
		ExcludedKbs   = @($excludedKbs)
		DynamicScopes = @($dynamicScopes)
	}
}
