#Requires -Version 7.4
<#
.SYNOPSIS
	Installs the PowerShell modules of the DevOps dev container image.

.DESCRIPTION
	Runs once during 'docker build'. The modules land in the AllUsers scope
	(/usr/local/share/powershell/Modules), so the 'vscode' user and root both see them.

	Modules with a Version are pinned to exactly that version.
	Modules without a Version get the newest version at build time - the image tag freezes it.
	tests/image.Tests.ps1 prints the installed versions.
#>
[CmdletBinding()]
param ()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$modules = @(
	@{ Name = 'Pester'; Version = '5.7.1' }
	@{ Name = 'PSScriptAnalyzer'; Version = '1.24.0' }
	@{ Name = 'PSFramework' }
	@{ Name = 'powershell-yaml' }
	@{ Name = 'Az.Accounts' }
	@{ Name = 'Az.Resources' }
	@{ Name = 'Az.ContainerRegistry' }
	@{ Name = 'Microsoft.Graph.Authentication' }
)

# PSResourceGet ships with PowerShell 7.4 and newer
Set-PSResourceRepository -Name PSGallery -Trusted

foreach ($module in $modules) {
	Write-Host "Installing $($module.Name) $($module.Version) ..."
	Install-PSResource @module -Scope AllUsers -TrustRepository -AcceptLicense -Quiet
}

Get-InstalledPSResource -Scope AllUsers |
	Sort-Object Name |
	Format-Table Name, Version -AutoSize |
	Out-String |
	Write-Host
