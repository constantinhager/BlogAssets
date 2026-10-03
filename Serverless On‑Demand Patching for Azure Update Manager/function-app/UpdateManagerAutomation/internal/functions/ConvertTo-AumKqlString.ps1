function ConvertTo-AumKqlString {
	<#
	.SYNOPSIS
		Escapes a value for use inside a single-quoted KQL string literal.

	.DESCRIPTION
		Tag names and values come from the HTTP caller.
		Escaping backslashes and single quotes prevents KQL injection.

	.PARAMETER Value
		The raw value.

	.EXAMPLE
		PS C:\> "tags['$(ConvertTo-AumKqlString -Value $TagName)']"

		Safely embeds the tag name in a query.
	#>
	[OutputType([string])]
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[AllowEmptyString()]
		[string]
		$Value
	)

	$Value.Replace('\', '\\').Replace("'", "\'")
}
