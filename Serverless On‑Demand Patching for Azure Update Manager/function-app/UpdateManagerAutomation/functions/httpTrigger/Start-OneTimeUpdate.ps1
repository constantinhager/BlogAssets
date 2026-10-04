function Start-OneTimeUpdate {
	<#
	.SYNOPSIS
		"One-time update": installs updates on machines selected by tag and/or by name, minus the KBs on the exclusion list.

	.DESCRIPTION
		1. Selects the machines (Azure VMs and Arc-enabled servers, Azure Resource Graph):
		   - by tag (TagName + TagValue) and/or
		   - by name or resource ID (MachineName).
		   If both are given, the machines of both selections are updated (each machine once).
		2. Reads the excluded KBs from Azure Table Storage:
		   all rows in partition 'Global' plus all rows in the partition named like the tag value
		   (or like ExclusionScope, if given).
		3. Calls installPatches on each machine.
		   Windows machines get the exclusion list in windowsParameters.kbNumbersToExclude.
		   Linux machines get linuxParameters (KB exclusions do not apply to Linux packages).

		Published as HTTP endpoint: /api/Start-OneTimeUpdate

	.PARAMETER TagName
		Name of the tag, e.g. 'UpdateGroup'. Must be used together with TagValue.

	.PARAMETER TagValue
		Value of the tag, e.g. 'Wave1'. Also used as the table partition for group-specific exclusions.

	.PARAMETER MachineName
		Names of the machines to update, e.g. 'vm-aum-01','vm-aum-02' (JSON array or comma separated).
		A full resource ID selects exactly one machine. A name that exists in several resource groups
		or subscriptions selects all of them.

	.PARAMETER ExclusionScope
		Table partition for group-specific KB exclusions, on top of 'Global'.
		Defaults to TagValue. Use it when you select machines by name.

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

	.EXAMPLE
		POST /api/Start-OneTimeUpdate
		{ "MachineName": ["vm-aum-01", "vm-aum-02"], "ExclusionScope": "Wave1" }

		Installs Critical and Security updates on exactly these two machines, except the KBs
		listed in the exclusion table for 'Global' and 'Wave1'.
	#>
	[CmdletBinding()]
	param (
		[string]
		$TagName,

		[string]
		$TagValue,

		[string[]]
		$MachineName,

		[string]
		$ExclusionScope,

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

	$machineNames = @(ConvertTo-AumStringArray -InputObject $MachineName)
	if (($TagName -and -not $TagValue) -or ($TagValue -and -not $TagName)) { throw 'TagName and TagValue must be used together.' }
	if (-not $TagName -and -not $machineNames) { throw 'Specify TagName and TagValue, MachineName, or both.' }

	$windowsClassifications = @(ConvertTo-AumStringArray -InputObject $Classification)
	$linuxClassifications = @(ConvertTo-AumStringArray -InputObject $LinuxClassification)

	$validWindows = 'Critical', 'Security', 'UpdateRollUp', 'FeaturePack', 'ServicePack', 'Definition', 'Tools', 'Updates'
	$validLinux = 'Critical', 'Security', 'Other'
	foreach ($entry in $windowsClassifications) { if ($entry -notin $validWindows) { throw "Invalid Windows classification '$entry'. Valid: $($validWindows -join ', ')" } }
	foreach ($entry in $linuxClassifications) { if ($entry -notin $validLinux) { throw "Invalid Linux classification '$entry'. Valid: $($validLinux -join ', ')" } }

	# Exclusion list: table (Global + tag value / exclusion scope) + ad-hoc additions
	if (-not $ExclusionScope) { $ExclusionScope = $TagValue }
	$exclusions = @(Get-AumExcludedKb -Scope $ExclusionScope)
	$excludedKbs = @(ConvertTo-AumKbNumber -Kb (@($exclusions.Kb) + @(ConvertTo-AumStringArray -InputObject $AdditionalExcludedKb)))
	Write-Host "Start-OneTimeUpdate: excluding $($excludedKbs.Count) KB(s): $($excludedKbs -join ', ')"

	$subscriptions = @(ConvertTo-AumStringArray -InputObject $SubscriptionId)
	$machines = [System.Collections.Generic.List[object]]::new()
	if ($TagName) {
		foreach ($machine in @(Get-AumTaggedMachine -TagName $TagName -TagValue $TagValue -SubscriptionId $subscriptions)) { $machines.Add($machine) }
		Write-Host "Start-OneTimeUpdate: $($machines.Count) machine(s) found for tag $TagName=$TagValue"
	}

	$notFound = @()
	if ($machineNames) {
		$named = @(Get-AumMachineByName -Name $machineNames -SubscriptionId $subscriptions)
		foreach ($machine in $named) {
			if (-not ($machines | Where-Object { $_.id -eq $machine.id })) { $machines.Add($machine) }
		}
		# An entry counts as found if it matches a machine name or a machine ID
		$notFound = @($machineNames | Where-Object { $entry = $_; -not ($named | Where-Object { $_.name -eq $entry -or $_.id -eq $entry }) })
		foreach ($entry in $notFound) { Write-Warning "Start-OneTimeUpdate: no machine found for '$entry'." }
		Write-Host "Start-OneTimeUpdate: $($named.Count) machine(s) found for $($machineNames.Count) requested name(s)"
	}

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
		Tag             = $(if ($TagName) { "$TagName=$TagValue" })
		RequestedNames  = @($machineNames)
		NotFound        = @($notFound)
		RebootSetting   = $RebootSetting
		MaximumDuration = $MaximumDuration
		ExcludedKbs     = @($excludedKbs)
		MachineCount    = $machines.Count
		Accepted        = @($results | Where-Object Status -EQ 'Accepted').Count
		Machines        = @($results)
	}
}
