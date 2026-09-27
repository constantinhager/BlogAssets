function Move-TriggerBlob {
	<#
	.SYNOPSIS
		Moves a blob into another container of the same storage account.

	.DESCRIPTION
		Called by the blob trigger wrapper (build/functionBlob/run.ps1) after a file was handled:
		successful files go to the processed container, rejected ones to the failed container.
		The target must be a different container: a copy inside the input container would raise
		BlobCreated again and trigger the function a second time.

		Copies with Put Blob From URL (synchronous, server-side), then deletes the source.
		An existing target blob with the same name is overwritten, like the rows in SQL
		(the primary key is SourceBlob + RowNumber).
		With -ErrorMessage, the message is also written to '<name>.error.txt' next to the blob.

		Authenticates with Get-StorageAccessToken (managed identity in Azure).

	.PARAMETER BlobServiceUri
		Blob endpoint of the storage account, e.g. https://account.blob.core.windows.net/

	.PARAMETER BlobPath
		Container and blob name of the source, e.g. incoming/sample.csv (trigger metadata 'BlobTrigger').

	.PARAMETER TargetContainer
		Container to move the blob to.

	.PARAMETER ErrorMessage
		Why the file was rejected. Written to '<name>.error.txt' in the target container.

	.EXAMPLE
		PS C:\> Move-TriggerBlob -BlobServiceUri 'https://account.blob.core.windows.net/' -BlobPath 'incoming/sample.csv' -TargetContainer 'processed'

		Moves incoming/sample.csv to processed/sample.csv.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[string]
		$BlobServiceUri,

		[Parameter(Mandatory)]
		[string]
		$BlobPath,

		[Parameter(Mandatory)]
		[string]
		$TargetContainer,

		[string]
		$ErrorMessage
	)

	$sourceContainer, $blobName = $BlobPath -split '/', 2
	if (-not $blobName) {
		throw "BlobPath must be '<container>/<blob name>'. Got '$BlobPath'."
	}
	if ($sourceContainer -eq $TargetContainer) {
		throw "Target container '$TargetContainer' is the source container. The copy would trigger the function again."
	}

	# Escape each path segment (spaces, umlauts, # ...), keep the slashes of virtual folders
	$escapedName = ($blobName -split '/' | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
	$serviceUri = $BlobServiceUri.TrimEnd('/')
	$sourceUri = '{0}/{1}/{2}' -f $serviceUri, $sourceContainer, $escapedName
	$targetUri = '{0}/{1}/{2}' -f $serviceUri, $TargetContainer, $escapedName

	$token = Get-StorageAccessToken
	$headers = @{
		'Authorization' = "Bearer $token"
		'x-ms-version'  = '2023-11-03'
		'x-ms-date'     = [DateTime]::UtcNow.ToString('R')
	}

	# Put Blob From URL. The source needs its own authorization header, even in the same account.
	$copyHeaders = $headers.Clone()
	$copyHeaders['x-ms-blob-type'] = 'BlockBlob'
	$copyHeaders['x-ms-copy-source'] = $sourceUri
	$copyHeaders['x-ms-copy-source-authorization'] = "Bearer $token"
	$copyParam = @{
		Method  = 'Put'
		Uri     = $targetUri
		Headers = $copyHeaders
		Body    = [byte[]]::new(0)
	}
	try {
		$null = Invoke-RestMethod @copyParam
	} catch {
		# Event Grid delivers at least once: a parallel invocation may have moved the blob already
		if ($_.Exception.Response.StatusCode -eq [Net.HttpStatusCode]::NotFound) {
			Write-Warning "'$BlobPath' no longer exists, probably moved by another invocation."
			return
		}
		throw
	}

	if ($ErrorMessage) {
		$reportHeaders = $headers.Clone()
		$reportHeaders['x-ms-blob-type'] = 'BlockBlob'
		$reportParam = @{
			Method      = 'Put'
			Uri         = "$targetUri.error.txt"
			Headers     = $reportHeaders
			Body        = [Text.Encoding]::UTF8.GetBytes($ErrorMessage)
			ContentType = 'text/plain; charset=utf-8'
		}
		$null = Invoke-RestMethod @reportParam
	}

	try {
		$null = Invoke-RestMethod -Method Delete -Uri $sourceUri -Headers $headers
	} catch {
		# Already gone (e.g. a parallel retry moved it): nothing left to do
		if ($_.Exception.Response.StatusCode -ne [Net.HttpStatusCode]::NotFound) {
			throw
		}
	}
	Write-Verbose "Moved '$BlobPath' to '$TargetContainer'"
}
