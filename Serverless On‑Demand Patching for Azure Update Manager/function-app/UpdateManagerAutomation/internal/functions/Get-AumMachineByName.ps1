function Get-AumMachineByName {
	<#
	.SYNOPSIS
		Finds Azure VMs and Azure Arc-enabled servers by name or resource ID.

	.DESCRIPTION
		Uses Azure Resource Graph, so one call covers all subscriptions in scope.
		Names are compared case-insensitively. A name that exists in several resource groups
		or subscriptions returns every match; pass the full resource ID to select exactly one machine.

	.PARAMETER Name
		Machine names or full resource IDs (entries starting with '/').

	.PARAMETER SubscriptionId
		Optional list of subscriptions. Defaults to AUM_SUBSCRIPTION_IDS.

	.EXAMPLE
		PS C:\> Get-AumMachineByName -Name 'vm-aum-01', 'vm-aum-02'

		Returns the two machines.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string[]]
		$Name,

		[string[]]
		$SubscriptionId
	)

	if (-not $SubscriptionId) { $SubscriptionId = (Get-AumConfig).SubscriptionIds }

	$entries = @(ConvertTo-AumStringArray -InputObject $Name)
	if (-not $entries) { throw 'No machine name specified.' }
	if ($entries.Count -gt 200) { throw "Too many machines ($($entries.Count)). The limit is 200 per call." }

	$names = @($entries | Where-Object { -not $_.StartsWith('/') })
	$ids = @($entries | Where-Object { $_.StartsWith('/') })

	$conditions = [System.Collections.Generic.List[string]]::new()
	if ($names) { $conditions.Add("name in~ ($(($names | ForEach-Object { "'$(ConvertTo-AumKqlString -Value $_)'" }) -join ', '))") }
	if ($ids) { $conditions.Add("id in~ ($(($ids | ForEach-Object { "'$(ConvertTo-AumKqlString -Value $_)'" }) -join ', '))") }

	$query = @"
resources
| where type in~ ('microsoft.compute/virtualmachines', 'microsoft.hybridcompute/machines')
| where $($conditions -join ' or ')
| extend osType = iff(type =~ 'microsoft.compute/virtualmachines', tostring(properties.storageProfile.osDisk.osType), tostring(properties.osType))
| extend state = iff(type =~ 'microsoft.compute/virtualmachines', tostring(properties.extended.instanceView.powerState.code), tostring(properties.status))
| project id, name, type, resourceGroup, subscriptionId, location, osType, state
| order by name asc
"@

	Search-AumResourceGraph -Query $query -SubscriptionId $SubscriptionId
}
