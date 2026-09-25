param (
	[byte[]]
	$InputBlob,

	$TriggerMetadata
)

$ErrorActionPreference = 'Stop'
Write-Host "Trigger: %COMMAND% has been invoked for blob '$($TriggerMetadata.Name)'"

# Pass only the parameters the command declares
$command = Get-Command -Name '%COMMAND%'
$parameters = @{}
if ($command.Parameters.ContainsKey('InputBlob')) { $parameters.InputBlob = $InputBlob }
if ($command.Parameters.ContainsKey('BlobName')) { $parameters.BlobName = $TriggerMetadata.Name }
if ($command.Parameters.ContainsKey('TriggerMetadata')) { $parameters.TriggerMetadata = $TriggerMetadata }

try {
	$results = & $command @parameters -ErrorAction Stop
}
catch {
	$_ | Out-String | ForEach-Object {
		foreach ($line in ($_ -split "`n")) {
			Write-Warning $line
		}
	}
	# Rethrow: the runtime retries the blob and moves it to the poison queue after max retries
	throw
}

$outputBinding = '%OUTPUTBINDING%'
if ($outputBinding -and $results) {
	Push-OutputBinding -Name $outputBinding -Value @($results)
	Write-Host "Trigger: %COMMAND% pushed $(@($results).Count) item(s) to '$outputBinding'"
}
