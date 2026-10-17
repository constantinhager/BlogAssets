#Requires -Version 7.4
# .devcontainer/postCreate.ps1

$ErrorActionPreference = 'Stop'

# Pin the modules every team member must have in exactly this version.
# Without Version, Install-PSResource takes the newest one.
$modules = @(
    @{ Name = 'Pester'}
    @{ Name = 'PSScriptAnalyzer'}
    @{ Name = 'PSFramework' }
    @{ Name = 'EntraAuth' }
)

# PSResourceGet ships with PowerShell 7.4 and newer.
# On a fresh container the repository store doesn't exist yet and Set-PSResourceRepository
# fails; any Get-PSResourceRepository call creates it first.
$null = Get-PSResourceRepository
Set-PSResourceRepository -Name PSGallery -Trusted

foreach ($module in $modules) {
    Write-Host "Installing $($module.Name) ..."
    Install-PSResource @module -Scope CurrentUser -TrustRepository -Quiet
}

Get-InstalledPSResource -Scope CurrentUser |
    Sort-Object Name |
    Format-Table Name, Version, Repository -AutoSize
