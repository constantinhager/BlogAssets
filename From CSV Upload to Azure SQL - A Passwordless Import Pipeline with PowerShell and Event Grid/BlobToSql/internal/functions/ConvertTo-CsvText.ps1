function ConvertTo-CsvText {
	<#
	.SYNOPSIS
		Decodes the blob bytes into text, with a configured or detected encoding.

	.DESCRIPTION
		'auto' (default):
		1. A byte order mark decides: UTF-8, UTF-16 LE (Excel "Unicode Text") or UTF-16 BE.
		2. Without BOM: valid UTF-8 is read as UTF-8, anything else as windows-1252
		   (classic Excel "CSV (Trennzeichen-getrennt)" on a German/Western Windows).
		   Umlauts in windows-1252 are single bytes (ü = 0xFC), which is never valid UTF-8,
		   so the check is reliable in practice.

		A fixed encoding decodes as configured. Bytes that don't fit become U+FFFD, which ends up
		as '?' in SQL, so this case logs a warning.

	.PARAMETER Bytes
		Blob content.

	.PARAMETER Encoding
		auto, or an encoding name .NET knows, e.g. utf-8, windows-1252, utf-16.

	.PARAMETER BlobName
		Only used in messages.

	.EXAMPLE
		PS C:\> ConvertTo-CsvText -Bytes ([IO.File]::ReadAllBytes('.\sample-ansi.csv')) -Encoding auto

		Returns the text, decoded as windows-1252.
	#>
	[CmdletBinding()]
	[OutputType([string])]
	param (
		[Parameter(Mandatory)]
		[AllowEmptyCollection()]
		[byte[]]
		$Bytes,

		[string]
		$Encoding = 'auto',

		[string]
		$BlobName
	)

	# Code pages like windows-1252 need this provider on .NET (Core). PowerShell registers it,
	# a host like the Functions worker may not. Registering twice is harmless.
	[System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)

	if ($Encoding -and $Encoding -ne 'auto') {
		$text = [System.Text.Encoding]::GetEncoding($Encoding).GetString($Bytes)
		if ($text.Contains([char]0xFFFD)) {
			Write-Warning "'$BlobName' contains bytes that are not valid $Encoding. They become '?'. Set CSV_ENCODING to 'auto' or to the file's encoding."
		}
		return $text.TrimStart([char]0xFEFF)
	}

	$detected = $null
	if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) {
		$detected = [System.Text.Encoding]::UTF8
	} elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
		$detected = [System.Text.Encoding]::Unicode
	} elseif ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
		$detected = [System.Text.Encoding]::BigEndianUnicode
	}
	if ($detected) {
		Write-Verbose "'$BlobName': byte order mark, decoding as $($detected.WebName)"
		return $detected.GetString($Bytes).TrimStart([char]0xFEFF)
	}

	# Strict UTF-8 decoder: throws on the first invalid byte sequence instead of replacing it
	$strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)
	try {
		$text = $strictUtf8.GetString($Bytes)
		Write-Verbose "'$BlobName': valid UTF-8"
		return $text
	} catch [System.Text.DecoderFallbackException] {
		Write-Verbose "'$BlobName': not valid UTF-8, decoding as windows-1252"
		return [System.Text.Encoding]::GetEncoding(1252).GetString($Bytes)
	}
}
