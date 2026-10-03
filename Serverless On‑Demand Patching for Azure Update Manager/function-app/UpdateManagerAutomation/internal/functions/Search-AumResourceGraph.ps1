function Search-AumResourceGraph {
	<#
	.SYNOPSIS
		Runs an Azure Resource Graph (KQL) query via the REST API.

	.DESCRIPTION
		Calls POST /providers/Microsoft.ResourceGraph/resources and follows $skipToken paging.
		Without a subscription list, Resource Graph searches all subscriptions
		the Managed Identity can read.

	.PARAMETER Query
		The KQL query.

	.PARAMETER SubscriptionId
		Optional list of subscriptions to limit the query to.

	.EXAMPLE
		PS C:\> Search-AumResourceGraph -Query "resources | where type =~ 'microsoft.compute/virtualmachines'"

		Lists all virtual machines the identity can see.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]
		$Query,

		[string[]]
		$SubscriptionId
	)

	$results = [System.Collections.Generic.List[object]]::new()
	$skipToken = $null

	do {
		$body = @{
			query   = $Query
			options = @{ resultFormat = 'objectArray'; '$top' = 1000 }
		}
		if ($SubscriptionId) { $body.subscriptions = @($SubscriptionId) }
		if ($skipToken) { $body.options['$skipToken'] = $skipToken }

		$response = Invoke-AumArmRequest -Method POST -Path '/providers/Microsoft.ResourceGraph/resources' -ApiVersion $script:ApiVersion.ResourceGraph -Body $body
		foreach ($row in $response.Content.data) { $results.Add($row) }
		$skipToken = $response.Content.'$skipToken'
	}
	while ($skipToken)

	$results.ToArray()
}
