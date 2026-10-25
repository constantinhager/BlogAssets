function Get-SrEnvValue {
	<#
	.SYNOPSIS
		Reads one app setting (environment variable).

	.PARAMETER Name
		Name of the app setting.

	.PARAMETER Default
		Value to use if the app setting is missing or empty.

	.PARAMETER Mandatory
		Throw if the app setting is missing or empty.

	.PARAMETER AsBool
		Convert the value to a boolean ('true', '1', 'yes' are $true).

	.PARAMETER AsList
		Split the value on commas and semicolons and return the trimmed, non-empty parts.

	.EXAMPLE
		PS C:\> Get-SrEnvValue -Name 'SR_THRESHOLD_DAYS' -Default 30

		Returns the value of SR_THRESHOLD_DAYS or 30.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]
		$Name,

		$Default,

		[switch]
		$Mandatory,

		[switch]
		$AsBool,

		[switch]
		$AsList
	)

	$value = [Environment]::GetEnvironmentVariable($Name)
	if ([string]::IsNullOrWhiteSpace($value)) {
		if ($Mandatory) { throw "The app setting '$Name' is missing." }
		$value = $Default
	}
	if ($null -eq $value) {
		if ($AsBool) { return $false }
		if ($AsList) { return }
		return $null
	}

	$value = "$value".Trim()
	if ($AsBool) { return $value -in 'true', '1', 'yes' }
	if ($AsList) { return $value -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ } }
	$value
}
