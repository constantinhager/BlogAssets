function ConvertTo-AumKbNumber {
	<#
	.SYNOPSIS
		Normalizes KB identifiers to the plain number format the patch APIs use.

	.DESCRIPTION
		The table may contain 'KB5034439', 'kb5034439' or '5034439'.
		The installPatches API examples from Microsoft use the plain number ('5034439').
		Invalid entries are dropped with a warning.

	.PARAMETER Kb
		One or more KB identifiers.

	.EXAMPLE
		PS C:\> ConvertTo-AumKbNumber -Kb 'KB5034439', '890830'

		Returns '5034439', '890830'.
	#>
	[OutputType([string[]])]
	[CmdletBinding()]
	param (
		[AllowNull()]
		[AllowEmptyCollection()]
		[string[]]
		$Kb
	)

	$numbers = foreach ($entry in $Kb) {
		if (-not $entry) { continue }
		$clean = $entry.Trim() -replace '^(?i)KB', ''
		if ($clean -notmatch '^\d{4,8}$') {
			Write-Warning "Ignoring invalid KB number '$entry'"
			continue
		}
		$clean
	}
	$numbers | Select-Object -Unique
}
