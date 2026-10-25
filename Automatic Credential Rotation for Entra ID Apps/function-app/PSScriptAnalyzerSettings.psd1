@{
	Severity     = @('Error', 'Warning')
	ExcludeRules = @(
		# Write-Host is how a PowerShell function writes to the Functions log (Information level)
		'PSAvoidUsingWriteHost'
		# Internal helpers of a timer-triggered function app - nobody calls them interactively with -WhatIf
		'PSUseShouldProcessForStateChangingFunctions'
		# The build script writes the explicit list of functions into the manifest
		'PSUseToExportFieldsInManifest'
	)
}
