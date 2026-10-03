function Start-OneTimeUpdate {
	<#
	.SYNOPSIS
		"One-time update": installs updates on all machines with a given tag, minus the KBs on the exclusion list.

	.DESCRIPTION
		1. Finds all Azure VMs and Arc-enabled servers with the tag (Azure Resource Graph).
		2. Reads the excluded KBs from Azure Table Storage:
		   all rows in partition 'Global' plus all rows in the partition named like the tag value.
		3. Calls installPatches on each machine.
		   Windows machines get the exclusion list in windowsParameters.kbNumbersToExclude.
		   Linux machines get linuxParameters (KB exclusions do not apply to Linux packages).

		Published as HTTP endpoint: /api/Start-OneTimeUpdate

	.PARAMETER TagName
		Name of the tag, e.g. 'UpdateGroup'.

	.PARAMETER TagValue
		Value of the tag, e.g. 'Wave1'. Also used as the table partition for group-specific exclusions.

	.PARAMETER SubscriptionId
		Optional list of subscriptions. Defaults to the AUM_SUBSCRIPTION_IDS app setting.

	.PARAMETER RebootSetting
		IfRequired (default), Never or Always.

	.PARAMETER MaximumDuration
		ISO 8601 duration for the maintenance window of this run. Defaults to PT2H.

	.PARAMETER Classification
		Windows update classifications. Defaults to Critical, Security.

	.PARAMETER LinuxClassification
		Linux update classifications. Defaults to Critical, Security.

	.PARAMETER AdditionalExcludedKb
		Extra KBs to exclude for this run only, on top of the table.

	.EXAMPLE
		POST /api/Start-OneTimeUpdate
		{ "TagName": "UpdateGroup", "TagValue": "Wave1", "RebootSetting": "IfRequired" }

		Installs Critical and Security updates on all machines tagged UpdateGroup=Wave1,
		except the KBs listed in the exclusion table.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]
		$TagName,

		[Parameter(Mandatory = $true)]
		[string]
		$TagValue,

		[string[]]
		$SubscriptionId,

		[ValidateSet('IfRequired', 'Never', 'Always')]
		[string]
		$RebootSetting = 'IfRequired',

		[ValidatePattern('^PT(\d+H)?(\d+M)?$')]
		[string]
		$MaximumDuration = 'PT2H',

		[string[]]
		$Classification = @('Critical', 'Security'),

		[string[]]
		$LinuxClassification = @('Critical', 'Security'),

		[string[]]
		$AdditionalExcludedKb
	)

	$windowsClassifications = @(ConvertTo-AumStringArray -InputObject $Classification)
	$linuxClassifications = @(ConvertTo-AumStringArray -InputObject $LinuxClassification)

	$validWindows = 'Critical', 'Security', 'UpdateRollUp', 'FeaturePack', 'ServicePack', 'Definition', 'Tools', 'Updates'
	$validLinux = 'Critical', 'Security', 'Other'
	foreach ($entry in $windowsClassifications) { if ($entry -notin $validWindows) { throw "Invalid Windows classification '$entry'. Valid: $($validWindows -join ', ')" } }
	foreach ($entry in $linuxClassifications) { if ($entry -notin $validLinux) { throw "Invalid Linux classification '$entry'. Valid: $($validLinux -join ', ')" } }

	# Exclusion list: table (Global + tag value) + ad-hoc additions
	$exclusions = @(Get-AumExcludedKb -Scope $TagValue)
	$excludedKbs = @(ConvertTo-AumKbNumber -Kb (@($exclusions.Kb) + @(ConvertTo-AumStringArray -InputObject $AdditionalExcludedKb)))
	Write-Host "Start-OneTimeUpdate: excluding $($excludedKbs.Count) KB(s): $($excludedKbs -join ', ')"

	$subscriptions = @(ConvertTo-AumStringArray -InputObject $SubscriptionId)
	$machines = @(Get-AumTaggedMachine -TagName $TagName -TagValue $TagValue -SubscriptionId $subscriptions)
	Write-Host "Start-OneTimeUpdate: $($machines.Count) machine(s) found for tag $TagName=$TagValue"

	$results = foreach ($machine in $machines) {
		$body = @{
			maximumDuration = $MaximumDuration
			rebootSetting   = $RebootSetting
		}

		if ($machine.osType -eq 'Linux') {
			$body.linuxParameters = @{ classificationsToInclude = @($linuxClassifications) }
		}
		else {
			$body.windowsParameters = @{
				classificationsToInclude = @($windowsClassifications)
				kbNumbersToExclude       = @($excludedKbs)
			}
		}

		Invoke-AumPatchOperation -Machine $machine -Operation installPatches -Body $body
	}

	[pscustomobject]@{
		Operation       = 'OneTimeUpdate'
		Tag             = "$TagName=$TagValue"
		RebootSetting   = $RebootSetting
		MaximumDuration = $MaximumDuration
		ExcludedKbs     = @($excludedKbs)
		MachineCount    = $machines.Count
		Accepted        = @($results | Where-Object Status -EQ 'Accepted').Count
		Machines        = @($results)
	}
}
