#Requires -Version 7.4
<#
.SYNOPSIS
	Runs the Pester smoke tests inside the image and sets the exit code for the pipeline.
#>
[CmdletBinding()]
param ()

$config = New-PesterConfiguration
$config.Run.Path = Join-Path $PSScriptRoot 'image.Tests.ps1'
$config.Run.Exit = $true
$config.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $config
