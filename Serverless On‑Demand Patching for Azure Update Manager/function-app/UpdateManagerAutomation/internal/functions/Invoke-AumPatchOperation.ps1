function Invoke-AumPatchOperation {
	<#
	.SYNOPSIS
		Starts assessPatches or installPatches on one machine (Azure VM or Arc-enabled server).

	.DESCRIPTION
		Both operations are long-running ARM operations.
		ARM answers with 202 Accepted. We do not wait for the result: an HTTP-triggered function has a hard
		response limit of 230 seconds, an update run can take hours. The result shows up in Azure Update Manager.
		The ARM operation URL is not returned, because it cannot be called without an ARM token.

		Machines that are not running (VM) or not connected (Arc) are skipped.

	.PARAMETER Machine
		A machine object as returned by Get-AumTaggedMachine.

	.PARAMETER Operation
		assessPatches or installPatches.

	.PARAMETER Body
		Request body for installPatches.

	.EXAMPLE
		PS C:\> Invoke-AumPatchOperation -Machine $vm -Operation assessPatches

		Starts an on-demand assessment on $vm.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		$Machine,

		[Parameter(Mandatory = $true)]
		[ValidateSet('assessPatches', 'installPatches')]
		[string]
		$Operation,

		$Body
	)

	$isArc = $Machine.type -eq 'microsoft.hybridcompute/machines'
	$apiVersion = if ($isArc) { $script:ApiVersion.HybridCompute } else { $script:ApiVersion.Compute }

	$result = [ordered]@{
		Name          = $Machine.name
		ResourceGroup = $Machine.resourceGroup
		Subscription  = $Machine.subscriptionId
		Kind          = $(if ($isArc) { 'ArcServer' } else { 'AzureVM' })
		OsType        = $Machine.osType
		State         = $Machine.state
		Status        = $null
		Message       = $null
	}

	$isReady = if ($isArc) { $Machine.state -eq 'Connected' } else { $Machine.state -eq 'PowerState/running' }
	if (-not $isReady) {
		$result.Status = 'Skipped'
		$result.Message = "Machine is not running/connected (state: $($Machine.state))."
		return [pscustomobject]$result
	}

	try {
		$param = @{
			Method     = 'POST'
			Path       = "$($Machine.id)/$Operation"
			ApiVersion = $apiVersion
		}
		if ($Body) { $param.Body = $Body }

		$null = Invoke-AumArmRequest @param
		$result.Status = 'Accepted'
	}
	catch {
		$result.Status = 'Failed'
		$result.Message = "$_"
	}

	[pscustomobject]$result
}
