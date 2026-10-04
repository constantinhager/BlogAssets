function Get-UpdateManagerMachine {
	<#
	.SYNOPSIS
		Lists all machines Azure Update Manager can manage, with their latest assessment summary.

	.DESCRIPTION
		Azure Update Manager works on Azure VMs and Azure Arc-enabled servers.
		This endpoint lists both via Azure Resource Graph and joins the latest
		patch assessment result (patchassessmentresources) to each machine.

		Published as HTTP endpoint: /api/Get-UpdateManagerMachine

	.PARAMETER TagName
		Optional tag name filter.

	.PARAMETER TagValue
		Optional tag value filter (requires TagName).

	.PARAMETER OsType
		Optional filter: Windows or Linux.

	.PARAMETER SubscriptionId
		Optional list of subscriptions. Defaults to the AUM_SUBSCRIPTION_IDS app setting.

	.NOTES
		OtherUpdates is the number of all available updates that are neither Critical nor Security:
		'other' on Linux, and UpdateRollup, FeaturePack, ServicePack, Definition, Tools and Updates on Windows.

	.EXAMPLE
		GET /api/Get-UpdateManagerMachine

		Lists all VMs and Arc servers in scope.

	.EXAMPLE
		GET /api/Get-UpdateManagerMachine?TagName=UpdateGroup&TagValue=Wave1&OsType=Windows

		Lists only Windows machines tagged UpdateGroup=Wave1.
	#>
	[CmdletBinding()]
	param (
		[string]
		$TagName,

		[string]
		$TagValue,

		[ValidateSet('Windows', 'Linux')]
		[string]
		$OsType,

		[string[]]
		$SubscriptionId
	)

	$filters = [System.Collections.Generic.List[string]]::new()
	if ($TagName) {
		$tagFilter = "tostring(t[0]) =~ '$(ConvertTo-AumKqlString -Value $TagName)'"
		if ($TagValue) { $tagFilter += " and tostring(t[1]) =~ '$(ConvertTo-AumKqlString -Value $TagValue)'" }
		# Expand a copy of the tag bag, so the original tags column stays intact for the output.
		# Tag names are case-insensitive in Azure, hence =~ instead of tags['Name'].
		$filters.Add("| extend t = tags | mv-expand bagexpansion=array t | where $tagFilter | project-away t")
	}
	if ($OsType) { $filters.Add("| where osType =~ '$OsType'") }

	$query = @"
resources
| where type in~ ('microsoft.compute/virtualmachines', 'microsoft.hybridcompute/machines')
| extend osType = iff(type =~ 'microsoft.compute/virtualmachines', tostring(properties.storageProfile.osDisk.osType), tostring(properties.osType))
$($filters -join "`n")
| extend machineId = tolower(id)
| extend machineKind = iff(type =~ 'microsoft.compute/virtualmachines', 'AzureVM', 'ArcServer')
| extend state = iff(type =~ 'microsoft.compute/virtualmachines', tostring(properties.extended.instanceView.powerState.code), tostring(properties.status))
| extend patchSettings = iff(osType =~ 'windows', properties.osProfile.windowsConfiguration.patchSettings, properties.osProfile.linuxConfiguration.patchSettings)
| extend patchMode = tostring(patchSettings.patchMode), assessmentMode = tostring(patchSettings.assessmentMode)
| project machineId, id, name, machineKind, osType, state, patchMode, assessmentMode, resourceGroup, subscriptionId, location, tags
| join kind=leftouter (
    patchassessmentresources
    | where type in~ ('microsoft.compute/virtualmachines/patchassessmentresults', 'microsoft.hybridcompute/machines/patchassessmentresults')
    | extend machineId = tostring(split(tolower(id), '/patchassessmentresults/')[0])
    | extend counts = properties.availablePatchCountByClassification
    | project machineId,
        lastAssessment = todatetime(properties.lastModifiedDateTime),
        assessmentStatus = tostring(properties.status),
        rebootPending = tobool(properties.rebootPending),
        criticalUpdates = toint(counts.critical),
        securityUpdates = toint(counts.security),
        otherUpdates = coalesce(toint(counts.other), 0) + coalesce(toint(counts.updateRollup), 0) + coalesce(toint(counts.featurePack), 0) + coalesce(toint(counts.servicePack), 0) + coalesce(toint(counts.definition), 0) + coalesce(toint(counts.tools), 0) + coalesce(toint(counts.updates), 0)
) on machineId
| project-away machineId, machineId1
| order by name asc
"@

	$subscriptions = @(ConvertTo-AumStringArray -InputObject $SubscriptionId)
	if (-not $subscriptions) { $subscriptions = (Get-AumConfig).SubscriptionIds }

	$machines = @(Search-AumResourceGraph -Query $query -SubscriptionId $subscriptions)
	foreach ($machine in $machines) {
		[pscustomobject]@{
			Name             = $machine.name
			Kind             = $machine.machineKind
			OsType           = $machine.osType
			State            = $machine.state
			PatchMode        = $machine.patchMode
			AssessmentMode   = $machine.assessmentMode
			LastAssessment   = $machine.lastAssessment
			AssessmentStatus = $machine.assessmentStatus
			RebootPending    = $machine.rebootPending
			CriticalUpdates  = $machine.criticalUpdates
			SecurityUpdates  = $machine.securityUpdates
			OtherUpdates     = $machine.otherUpdates
			ResourceGroup    = $machine.resourceGroup
			Subscription     = $machine.subscriptionId
			Location         = $machine.location
			Tags             = $machine.tags
			Id               = $machine.id
		}
	}
}
