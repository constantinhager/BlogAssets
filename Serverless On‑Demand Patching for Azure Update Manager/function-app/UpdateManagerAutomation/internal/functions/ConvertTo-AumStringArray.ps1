function ConvertTo-AumStringArray {
	<#
	.SYNOPSIS
		Normalizes list input from an HTTP request into a clean string array.

	.DESCRIPTION
		Query string parameters arrive as a single string ("Critical,Security").
		JSON bodies arrive as real arrays (["Critical","Security"]).
		This helper accepts both and returns trimmed, de-duplicated strings.
		Wrap the call in @() to always get an array.

	.PARAMETER InputObject
		The raw value(s).

	.EXAMPLE
		PS C:\> ConvertTo-AumStringArray -InputObject 'Critical, Security'

		Returns 'Critical','Security'.
	#>
	[OutputType([string[]])]
	[CmdletBinding()]
	param (
		[AllowNull()]
		[AllowEmptyCollection()]
		[object[]]
		$InputObject
	)

	$values = foreach ($item in $InputObject) {
		if ($null -eq $item) { continue }
		foreach ($part in ([string]$item -split ',')) {
			$part = $part.Trim()
			if ($part) { $part }
		}
	}
	$values | Select-Object -Unique
}
