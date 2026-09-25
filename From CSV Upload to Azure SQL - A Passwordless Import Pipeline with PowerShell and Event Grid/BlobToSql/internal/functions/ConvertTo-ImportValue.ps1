function ConvertTo-ImportValue {
	<#
	.SYNOPSIS
		Converts a CSV string value to the type of its target SQL column.

	.DESCRIPTION
		Throws a readable error when the value cannot be converted.
		- Decimal:  accepts 1234.5, 1234,5, 1.234,5 and 1,234.5 (the last separator is the decimal separator)
		- DateTime: values with Z or an offset are converted to UTC.
		            Values without offset are interpreted in -TimeZone and converted to UTC.
		            Returned as 'yyyy-MM-ddTHH:mm:ss.fff' (for datetime2).

	.PARAMETER Value
		The raw CSV value.

	.PARAMETER Definition
		One entry of $script:ImportSchema.

	.PARAMETER TimeZone
		Time zone for DateTime values without offset.

	.EXAMPLE
		PS C:\> ConvertTo-ImportValue -Value '21,5' -Definition $script:ImportSchema[2] -TimeZone ([TimeZoneInfo]::Utc)

		Returns 21.5
	#>
	[CmdletBinding()]
	param (
		[AllowNull()]
		[AllowEmptyString()]
		[string]
		$Value,

		[Parameter(Mandatory)]
		$Definition,

		[Parameter(Mandatory)]
		[TimeZoneInfo]
		$TimeZone
	)

	$inv = [System.Globalization.CultureInfo]::InvariantCulture
	$column = $Definition.Column

	if ([string]::IsNullOrWhiteSpace($Value)) {
		if ($Definition.Required) { throw "Column '$column' is required but empty." }
		return $null
	}
	$text = $Value.Trim()

	switch ($Definition.Type) {
		'String' {
			if ($Definition.MaxLength -and $text.Length -gt $Definition.MaxLength) {
				throw "Column '$column' is longer than $($Definition.MaxLength) characters."
			}
			return $text
		}
		'Int' {
			$result = 0
			if (-not [int]::TryParse($text, [System.Globalization.NumberStyles]::Integer, $inv, [ref]$result)) {
				throw "Column '$column': '$text' is not a whole number."
			}
			return $result
		}
		'Decimal' {
			$normalized = $text -replace '\s', ''
			$lastDot = $normalized.LastIndexOf('.')
			$lastComma = $normalized.LastIndexOf(',')
			if ($lastComma -gt $lastDot) { $normalized = $normalized.Replace('.', '').Replace(',', '.') }
			else { $normalized = $normalized.Replace(',', '') }

			$result = [decimal]0
			if (-not [decimal]::TryParse($normalized, [System.Globalization.NumberStyles]::Number, $inv, [ref]$result)) {
				throw "Column '$column': '$text' is not a number."
			}
			return $result
		}
		'DateTime' {
			# Explicit offset or Z -> honor it
			if ($text -match '(Z|[+-]\d{2}:?\d{2})$' -and $text -match '\d[T ]\d') {
				$dto = [DateTimeOffset]::MinValue
				if ([DateTimeOffset]::TryParse($text, $inv, [System.Globalization.DateTimeStyles]::None, [ref]$dto)) {
					return $dto.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fff', $inv)
				}
			}

			$formats = [string[]]@(
				'yyyy-MM-ddTHH:mm:ss.FFFFFFF', 'yyyy-MM-dd HH:mm:ss.FFFFFFF', 'yyyy-MM-ddTHH:mm', 'yyyy-MM-dd HH:mm', 'yyyy-MM-dd'
				'dd.MM.yyyy HH:mm:ss', 'dd.MM.yyyy HH:mm', 'dd.MM.yyyy', 'd.M.yyyy H:mm:ss', 'd.M.yyyy H:mm', 'd.M.yyyy'
			)
			$local = [DateTime]::MinValue
			if (-not [DateTime]::TryParseExact($text, $formats, $inv, [System.Globalization.DateTimeStyles]::None, [ref]$local)) {
				throw "Column '$column': '$text' is not a supported date/time (ISO 8601 or dd.MM.yyyy [HH:mm[:ss]])."
			}
			$utc = [TimeZoneInfo]::ConvertTimeToUtc([DateTime]::SpecifyKind($local, 'Unspecified'), $TimeZone)
			return $utc.ToString('yyyy-MM-ddTHH:mm:ss.fff', $inv)
		}
		default { throw "Unsupported type '$($Definition.Type)' for column '$column'." }
	}
}
