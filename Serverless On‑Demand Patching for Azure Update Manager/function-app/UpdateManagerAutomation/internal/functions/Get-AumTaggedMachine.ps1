function Get-AumTaggedMachine {
	<#
	.SYNOPSIS
		Finds all Azure VMs and Azure Arc-enabled servers with a specific tag.

	.DESCRIPTION
		Uses Azure Resource Graph, so one call covers all subscriptions in scope.
		Tag names in Azure are case-insensitive, so the query expands the tag bag
		and compares name and value with =~ instead of a case-sensitive tags['Name'] lookup.

	.PARAMETER TagName
		Name of the tag.

	.PARAMETER TagValue
		Value of the tag.

	.PARAMETER SubscriptionId
		Optional list of subscriptions. Defaults to AUM_SUBSCRIPTION_IDS.

	.EXAMPLE
		PS C:\> Get-AumTaggedMachine -TagName 'UpdateGroup' -TagValue 'Wave1'

		Returns all machines tagged UpdateGroup=Wave1.
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

	if (-not $SubscriptionId) { $SubscriptionId = (Get-AumConfig).SubscriptionIds }

	$query = @"
resources
| where type in~ ('microsoft.compute/virtualmachines', 'microsoft.hybridcompute/machines')
| mv-expand bagexpansion=array tags
| where tostring(tags[0]) =~ '$(ConvertTo-AumKqlString -Value $TagName)' and tostring(tags[1]) =~ '$(ConvertTo-AumKqlString -Value $TagValue)'
| extend osType = iff(type =~ 'microsoft.compute/virtualmachines', tostring(properties.storageProfile.osDisk.osType), tostring(properties.osType))
| extend state = iff(type =~ 'microsoft.compute/virtualmachines', tostring(properties.extended.instanceView.powerState.code), tostring(properties.status))
| project id, name, type, resourceGroup, subscriptionId, location, osType, state
| distinct id, name, type, resourceGroup, subscriptionId, location, osType, state
| order by name asc
"@

	Search-AumResourceGraph -Query $query -SubscriptionId $SubscriptionId
}
