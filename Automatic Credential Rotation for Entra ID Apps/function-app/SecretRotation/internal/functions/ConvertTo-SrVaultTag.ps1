function ConvertTo-SrVaultTag {
	<#
	.SYNOPSIS
		Makes a hashtable safe to use as Key Vault tags.

	.DESCRIPTION
		Key Vault allows 15 tags per object, tag names up to 512 and values up to 256 characters.
		Empty values are dropped, long values are shortened, values are converted to strings.

	.PARAMETER Tags
		The tags.

	.EXAMPLE
		PS C:\> ConvertTo-SrVaultTag -Tags @{ appId = $appId; displayName = $name }

		Returns the cleaned tags.
	#>
	[OutputType([hashtable])]
	[CmdletBinding()]
	param (
		[hashtable]
		$Tags = @{}
	)

	$result = @{}
	foreach ($key in ($Tags.Keys | Sort-Object | Select-Object -First 15)) {
		$value = $Tags[$key]
		if ($null -eq $value -or "$value" -eq '') { continue }
		if ($value -is [DateTime] -or $value -is [DateTimeOffset]) { $value = $value.ToString('o') }
		$text = "$value"
		if ($text.Length -gt 256) { $text = $text.Substring(0, 256) }
		$result[$key] = $text
	}
	$result
}
