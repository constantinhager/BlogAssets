param (
	[byte[]]
	$InputBlob,

	$TriggerMetadata
)

$ErrorActionPreference = 'Stop'
Write-Host "Trigger: %COMMAND% has been invoked for blob '$($TriggerMetadata.Name)'"

# Import explicitly. With auto-loading, parallel invocations in a fresh worker (one runspace each)
# race while loading the module, and some fail with "'%COMMAND%' is not recognized".
Import-Module -Name '%MODULE%'

# Pass only the parameters the command declares
$command = Get-Command -Name '%COMMAND%'
$parameters = @{}
if ($command.Parameters.ContainsKey('InputBlob')) {
	$parameters.InputBlob = $InputBlob
}
if ($command.Parameters.ContainsKey('BlobName')) {
	$parameters.BlobName = $TriggerMetadata.Name
}
if ($command.Parameters.ContainsKey('TriggerMetadata')) {
	$parameters.TriggerMetadata = $TriggerMetadata
}

# Optional: move handled blobs out of the input container (app settings, set by Terraform)
$moveParam = @{
	BlobServiceUri = [Environment]::GetEnvironmentVariable('%CONNECTION%__blobServiceUri')
	BlobPath       = $TriggerMetadata.BlobTrigger
}

try {
	$results = & $command @parameters -ErrorAction Stop
} catch {
	if (-not $env:BLOB_FAILED_CONTAINER) {
		# No failed container: rethrow, the runtime retries and moves the blob to the poison queue
		throw
	}
	# The command rejected the file. Retrying the same content would fail again, so move it
	# to the failed container with the reason next to it, and log an error without failing the run.
	$message = $_.Exception.Message
	Move-TriggerBlob @moveParam -TargetContainer $env:BLOB_FAILED_CONTAINER -ErrorMessage $message
	Write-Error -Message "Trigger: '$($TriggerMetadata.Name)' rejected and moved to '$($env:BLOB_FAILED_CONTAINER)': $message" -ErrorAction Continue
	return
}

$outputBinding = '%OUTPUTBINDING%'
if ($outputBinding -and $results) {
	Push-OutputBinding -Name $outputBinding -Value @($results)
	Write-Host "Trigger: %COMMAND% pushed $(@($results).Count) item(s) to '$outputBinding'"
}

# The output binding writes after this script returns. If that write fails, the blob is already
# in the processed container and the retry finds no source blob: copy it back to re-import it.
if ($env:BLOB_PROCESSED_CONTAINER) {
	Move-TriggerBlob @moveParam -TargetContainer $env:BLOB_PROCESSED_CONTAINER
	Write-Host "Trigger: moved '$($TriggerMetadata.Name)' to '$($env:BLOB_PROCESSED_CONTAINER)'"
}
