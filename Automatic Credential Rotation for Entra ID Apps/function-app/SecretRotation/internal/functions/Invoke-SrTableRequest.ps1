function Invoke-SrTableRequest {
	<#
	.SYNOPSIS
		Calls the Azure Table Storage REST API of the renewal state table with a managed identity token.

	.DESCRIPTION
		Calls the Table service of SR_STATE_STORAGE_ACCOUNT with a token of the managed identity for
		https://storage.azure.com/ (Entra ID auth, no account key). The managed identity has
		'Storage Table Data Contributor' on the one table only.

		- Query (GET with $filter) follows the continuation headers and returns all entities, each with its ETag.
		- Merge (MERGE) inserts or merges an entity. With -IfMatch it only updates if the entity still has
		  that ETag and returns $false if someone changed it in the meantime (HTTP 412).
		- Delete (DELETE) removes an entity.

	.PARAMETER Operation
		Query, Merge or Delete.

	.PARAMETER Filter
		OData filter for Query, e.g. "PartitionKey eq '<tenant>'".

	.PARAMETER PartitionKey
		Partition key of the entity (Merge, Delete).

	.PARAMETER RowKey
		Row key of the entity (Merge, Delete).

	.PARAMETER Properties
		Properties to write (Merge). Only these properties are changed.

	.PARAMETER IfMatch
		ETag for optimistic concurrency (Merge, Delete). Without it, Merge inserts or merges and Delete uses '*'.

	.EXAMPLE
		PS C:\> Invoke-SrTableRequest -Operation Query -Filter "PartitionKey eq '$tenantId'"

		Returns all rows of a tenant.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[ValidateSet('Query', 'Merge', 'Delete')]
		[string]
		$Operation,

		[string]
		$Filter,

		[string]
		$PartitionKey,

		[string]
		$RowKey,

		[hashtable]
		$Properties = @{},

		[string]
		$IfMatch
	)

	$config = Get-SrConfig
	$base = 'https://{0}.table.core.windows.net/{1}' -f $config.StateStorageAccount, $config.StateTable
	$headers = @{
		Authorization  = 'Bearer {0}' -f (Get-SrAccessToken -Resource 'https://storage.azure.com/')
		'x-ms-version' = '2020-12-06'
		'x-ms-date'    = [DateTime]::UtcNow.ToString('R')
		Accept         = 'application/json;odata=minimalmetadata'
	}

	if ($Operation -eq 'Query') {
		$entities = [System.Collections.Generic.List[object]]::new()
		$query = ''
		if ($Filter) { $query = '?$filter=' + [uri]::EscapeDataString($Filter) }
		$nextPartition = $null; $nextRow = $null
		do {
			$uri = '{0}(){1}' -f $base, $query
			if ($nextPartition) {
				$separator = '?'; if ($query) { $separator = '&' }
				$uri += '{0}NextPartitionKey={1}&NextRowKey={2}' -f $separator, [uri]::EscapeDataString($nextPartition), [uri]::EscapeDataString("$nextRow")
			}
			$response = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers -ResponseHeadersVariable responseHeaders -ErrorAction Stop
			foreach ($entity in $response.value) {
				$entity | Add-Member -NotePropertyName ETag -NotePropertyValue $entity.'odata.etag' -Force
				$entities.Add($entity)
			}
			$nextPartition = "$($responseHeaders['x-ms-continuation-NextPartitionKey'])"
			$nextRow = "$($responseHeaders['x-ms-continuation-NextRowKey'])"
		} while ($nextPartition)
		return $entities.ToArray()
	}

	if (-not $PartitionKey -or -not $RowKey) { throw "$Operation needs PartitionKey and RowKey." }
	$keys = "(PartitionKey='{0}',RowKey='{1}')" -f [uri]::EscapeDataString($PartitionKey.Replace("'", "''")), [uri]::EscapeDataString($RowKey.Replace("'", "''"))
	$uri = $base + $keys

	if ($Operation -eq 'Delete') {
		$headers['If-Match'] = '*'
		if ($IfMatch) { $headers['If-Match'] = $IfMatch }
		$null = Invoke-RestMethod -Method Delete -Uri $uri -Headers $headers -ErrorAction Stop
		return
	}

	# Merge: without If-Match this is "Insert Or Merge Entity", with If-Match "Merge Entity"
	if ($IfMatch) { $headers['If-Match'] = $IfMatch }
	$body = @{ PartitionKey = $PartitionKey; RowKey = $RowKey } + $Properties
	$json = $body | ConvertTo-Json -Depth 5 -Compress
	$null = Invoke-RestMethod -CustomMethod MERGE -Uri $uri -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($json)) `
		-ContentType 'application/json' -SkipHttpErrorCheck -StatusCodeVariable statusCode -ErrorAction Stop
	if ($statusCode -eq 412 -and $IfMatch) { return $false }
	if ($statusCode -ge 400) { throw "MERGE $($config.StateTable)$keys failed with HTTP $statusCode." }
	$true
}
