function Get-AumExcludedKb {
	<#
	.SYNOPSIS
		Reads the excluded KB numbers from Azure Table Storage via REST.

	.DESCRIPTION
		Table layout (one row per excluded update):

		PartitionKey  'Global' (applies to every run) or a tag value like 'Wave1' (applies to that group only)
		RowKey        The KB number, e.g. 'KB5034439'
		Title         Free text
		Reason        Why the update is blocked
		Enabled       Optional. 'false' / false disables the row without deleting it
		ExpiresOn     Optional. ISO date. After that date the row is ignored

		Authentication uses the Managed Identity with the 'Storage Table Data Reader' role.
		No account key, no SAS token.

	.PARAMETER Scope
		The partition keys to read in addition to 'Global' (usually the tag value).

	.PARAMETER StorageAccountName
		Defaults to AUM_EXCLUSION_STORAGE_ACCOUNT.

	.PARAMETER TableName
		Defaults to AUM_EXCLUSION_TABLE.

	.EXAMPLE
		PS C:\> Get-AumExcludedKb -Scope 'Wave1'

		Returns all active exclusions for 'Global' and 'Wave1'.
	#>
	[CmdletBinding()]
	param (
		[string[]]
		$Scope,

		[string]
		$StorageAccountName = (Get-AumConfig).ExclusionStorageAccount,

		[string]
		$TableName = (Get-AumConfig).ExclusionTable
	)

	if (-not $StorageAccountName) { throw 'No exclusion storage account configured (AUM_EXCLUSION_STORAGE_ACCOUNT).' }
	if ($TableName -notmatch '^[A-Za-z][A-Za-z0-9]{2,62}$') { throw "Invalid table name '$TableName'." }

	# OData filter: Global + requested scopes. Single quotes are escaped by doubling them.
	$partitions = @('Global') + @($Scope | Where-Object { $_ }) | Select-Object -Unique
	$filter = ($partitions | ForEach-Object { "PartitionKey eq '$($_.Replace("'", "''"))'" }) -join ' or '

	$baseUri = 'https://{0}.table.core.windows.net/{1}()' -f $StorageAccountName, $TableName
	$query = '$filter=' + [uri]::EscapeDataString($filter)

	$entities = [System.Collections.Generic.List[object]]::new()
	$continuation = ''

	do {
		$headers = @{
			Authorization  = "Bearer $(Get-AumAccessToken -Resource 'https://storage.azure.com/')"
			'x-ms-version' = $script:ApiVersion.TableService
			'x-ms-date'    = [DateTime]::UtcNow.ToString('R')
			Accept         = 'application/json;odata=nometadata'
		}

		$response = Invoke-RestMethod -Method Get -Uri "$($baseUri)?$query$continuation" -Headers $headers -ResponseHeadersVariable responseHeaders -ErrorAction Stop
		foreach ($entity in $response.value) { $entities.Add($entity) }

		# Table Storage pages via continuation headers instead of a nextLink
		$continuation = ''
		$nextPartition = @($responseHeaders['x-ms-continuation-NextPartitionKey'])[0]
		$nextRow = @($responseHeaders['x-ms-continuation-NextRowKey'])[0]
		if ($nextPartition) {
			$continuation = '&NextPartitionKey={0}' -f [uri]::EscapeDataString($nextPartition)
			if ($nextRow) { $continuation += '&NextRowKey={0}' -f [uri]::EscapeDataString($nextRow) }
		}
	}
	while ($continuation)

	$now = (Get-Date).ToUniversalTime()
	foreach ($entity in $entities) {
		# Terraform writes all entity properties as strings, the portal may write booleans.
		if ("$($entity.Enabled)" -eq 'false') { continue }
		if ($entity.ExpiresOn -and ([datetime]$entity.ExpiresOn).ToUniversalTime() -lt $now) { continue }

		[pscustomobject]@{
			Scope  = $entity.PartitionKey
			Kb     = $entity.RowKey
			Title  = $entity.Title
			Reason = $entity.Reason
		}
	}
}
