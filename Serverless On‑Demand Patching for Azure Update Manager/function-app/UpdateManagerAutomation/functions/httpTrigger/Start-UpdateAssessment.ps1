function Start-UpdateAssessment {
	<#
	.SYNOPSIS
		"Check for updates": starts an on-demand patch assessment on all machines with a given tag.

	.DESCRIPTION
		Finds all Azure VMs and Arc-enabled servers with the tag via Azure Resource Graph
		and calls the assessPatches action on each of them.

		Published as HTTP endpoint: /api/Start-UpdateAssessment

	.PARAMETER TagName
		Name of the tag, e.g. 'UpdateGroup'.

	.PARAMETER TagValue
		Value of the tag, e.g. 'Wave1'.

	.PARAMETER SubscriptionId
		Optional list of subscriptions (comma separated in the query string).
		Defaults to the AUM_SUBSCRIPTION_IDS app setting.

	.EXAMPLE
		POST /api/Start-UpdateAssessment
		{ "TagName": "UpdateGroup", "TagValue": "Wave1" }

		Starts an assessment on all machines tagged UpdateGroup=Wave1.
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
		$SubscriptionId
	)

	$subscriptions = @(ConvertTo-AumStringArray -InputObject $SubscriptionId)
	$machines = @(Get-AumTaggedMachine -TagName $TagName -TagValue $TagValue -SubscriptionId $subscriptions)
	Write-Host "Start-UpdateAssessment: $($machines.Count) machine(s) found for tag $TagName=$TagValue"

	$results = foreach ($machine in $machines) {
		Invoke-AumPatchOperation -Machine $machine -Operation assessPatches
	}

	[pscustomobject]@{
		Operation    = 'Assessment'
		Tag          = "$TagName=$TagValue"
		MachineCount = $machines.Count
		Accepted     = @($results | Where-Object Status -EQ 'Accepted').Count
		Machines     = @($results)
	}
}
