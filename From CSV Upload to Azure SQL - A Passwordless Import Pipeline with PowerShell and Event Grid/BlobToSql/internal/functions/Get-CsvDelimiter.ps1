function Get-CsvDelimiter {
	<#
	.SYNOPSIS
		Returns the CSV delimiter: the configured one, or a guess based on the header line.

	.PARAMETER HeaderLine
		First line of the file.

	.PARAMETER Setting
		Configured delimiter. 'auto' (or empty) = detect ; , or tab from the header line.

	.EXAMPLE
		PS C:\> Get-CsvDelimiter -HeaderLine 'MeasuredAt;DeviceId;Value' -Setting 'auto'

		Returns ';'
	#>
	[CmdletBinding()]
	[OutputType([char])]
	param (
		[Parameter(Mandatory)]
		[AllowEmptyString()]
		[string]
		$HeaderLine,

		[string]
		$Setting = 'auto'
	)

	if ($Setting -and $Setting -ne 'auto') {
		if ($Setting -in 'tab', '\t') { return [char]"`t" }
		if ($Setting.Length -ne 1) { throw "CSV_DELIMITER must be a single character, 'tab' or 'auto'. Got '$Setting'." }
		return [char]$Setting
	}

	$candidates = foreach ($char in ';', ',', "`t") {
		[PSCustomObject]@{ Char = [char]$char; Count = ($HeaderLine.ToCharArray() | Where-Object { $_ -eq $char }).Count }
	}
	$best = $candidates | Sort-Object Count -Descending | Select-Object -First 1
	if ($best.Count -eq 0) { return [char]',' } # single-column file
	$best.Char
}
