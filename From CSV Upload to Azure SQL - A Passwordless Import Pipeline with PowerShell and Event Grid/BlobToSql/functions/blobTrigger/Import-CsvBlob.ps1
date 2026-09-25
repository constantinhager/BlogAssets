function Import-CsvBlob {
	<#
	.SYNOPSIS
		Parses a CSV blob into rows for dbo.ImportedRecord.

	.DESCRIPTION
		Published as blob-triggered function endpoint (see build/build.config.psd1 > BlobTrigger).
		The rows it returns are pushed into the SQL output binding by the generated run.ps1.

		All or nothing: if any row is invalid, the function throws and returns nothing.
		The runtime then retries and finally moves the blob to the poison queue.

		Settings (app settings / environment variables):
		- CSV_FILE_EXTENSIONS  Comma-separated list of accepted extensions. Default: .csv
		- CSV_DELIMITER        ; , tab or auto. Default: auto (detected from the header line)
		- CSV_ENCODING         utf-8 or windows-1252 (classic Excel "CSV (Trennzeichen-getrennt)"). Default: utf-8
		- CSV_SOURCE_TIMEZONE  Time zone of timestamps without offset, e.g. Europe/Berlin. Default: UTC

	.PARAMETER InputBlob
		Blob content as bytes.

	.PARAMETER BlobName
		Blob name relative to the container (from the trigger path {name}).

	.EXAMPLE
		PS C:\> Import-CsvBlob -InputBlob ([IO.File]::ReadAllBytes('.\sample.csv')) -BlobName 'sample.csv'

		Parses a local file the same way the function does.
	#>
	[CmdletBinding()]
	[OutputType([PSCustomObject])]
	param (
		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[byte[]]
		$InputBlob,

		[Parameter(Mandatory)]
		[string]
		$BlobName
	)

	#region Settings
	$extensions = ($env:CSV_FILE_EXTENSIONS, '.csv' | Where-Object { $_ } | Select-Object -First 1) -split ',' | ForEach-Object { $_.Trim() }
	$delimiterSetting = $env:CSV_DELIMITER, 'auto' | Where-Object { $_ } | Select-Object -First 1
	$encodingName = $env:CSV_ENCODING, 'utf-8' | Where-Object { $_ } | Select-Object -First 1
	$timeZoneId = $env:CSV_SOURCE_TIMEZONE, 'UTC' | Where-Object { $_ } | Select-Object -First 1
	#endregion Settings

	if (-not ($extensions | Where-Object { $BlobName.EndsWith($_, [StringComparison]::OrdinalIgnoreCase) })) {
		Write-Warning "Skipping '$BlobName': extension not in '$($extensions -join ', ')'."
		return
	}
	if ($BlobName.Length -gt 400) {
		throw "Blob name longer than 400 characters (SourceBlob column / primary key limit): '$BlobName'"
	}

	$timeZone = [TimeZoneInfo]::FindSystemTimeZoneById($timeZoneId)
	$encoding = [System.Text.Encoding]::GetEncoding($encodingName)
	$text = $encoding.GetString($InputBlob).TrimStart([char]0xFEFF)
	if ([string]::IsNullOrWhiteSpace($text)) {
		Write-Warning "'$BlobName' is empty."
		return
	}

	$headerLine = ($text -split '\r?\n', 2)[0]
	$delimiter = Get-CsvDelimiter -HeaderLine $headerLine -Setting $delimiterSetting
	Write-Verbose "Parsing '$BlobName' ($($InputBlob.Length) bytes, encoding $encodingName, delimiter '$delimiter')"

	$records = @($text | ConvertFrom-Csv -Delimiter $delimiter)
	if ($records.Count -eq 0) {
		Write-Warning "'$BlobName' has a header but no data rows."
		return
	}

	#region Validate header
	$headers = $records[0].PSObject.Properties.Name
	$missing = $script:ImportSchema | Where-Object { $_.Column -notin $headers } | ForEach-Object Column
	if ($missing) {
		throw "'$BlobName': missing column(s) $($missing -join ', '). Found: $($headers -join ', '). Delimiter used: '$delimiter'."
	}
	$extra = $headers | Where-Object { $_ -notin $script:ImportSchema.Column }
	if ($extra) { Write-Warning "'$BlobName': ignoring column(s) $($extra -join ', ')." }
	#endregion Validate header

	$importedAt = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fff', [System.Globalization.CultureInfo]::InvariantCulture)
	$errors = [System.Collections.Generic.List[string]]::new()
	$rows = [System.Collections.Generic.List[object]]::new()

	for ($index = 0; $index -lt $records.Count; $index++) {
		$rowNumber = $index + 1
		$row = [ordered]@{
			SourceBlob = $BlobName
			RowNumber  = $rowNumber
		}
		$rowOk = $true
		foreach ($definition in $script:ImportSchema) {
			try {
				$row[$definition.Column] = ConvertTo-ImportValue -Value $records[$index].$($definition.Column) -Definition $definition -TimeZone $timeZone
			}
			catch {
				$errors.Add("Row ${rowNumber}: $($_.Exception.Message)")
				$rowOk = $false
			}
		}
		if (-not $rowOk) { continue }
		$row.ImportedAt = $importedAt
		$rows.Add([PSCustomObject]$row)
	}

	if ($errors.Count -gt 0) {
		$preview = ($errors | Select-Object -First 20) -join [Environment]::NewLine
		throw "'$BlobName' has $($errors.Count) invalid value(s). Nothing was imported.$([Environment]::NewLine)$preview"
	}

	Write-Verbose "Parsed $($rows.Count) row(s) from '$BlobName'"
	$rows.ToArray()
}
