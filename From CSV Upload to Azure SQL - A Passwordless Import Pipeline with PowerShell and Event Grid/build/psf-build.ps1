[CmdletBinding()]
param (
	[string]
	$Repository = 'PSGallery',

	[string]
	$AppRg,

	[string]
	$AppName,

	[switch]
	$Restart
)

$ErrorActionPreference = 'Stop'
trap {
	Write-Warning "Script failed: $_"
	throw $_
}

Invoke-WebRequest 'https://raw.githubusercontent.com/PowershellFrameworkCollective/PSFramework.NuGet/refs/heads/master/bootstrap.ps1' -UseBasicParsing | Invoke-Expression

$workingDirectory = Split-Path $PSScriptRoot
$config = Import-PowerShellDataFile -Path "$PSScriptRoot\build.config.psd1"

# Prepare output path and copy function folder
Remove-Item -Path "$workingDirectory/publish" -Recurse -Force -ErrorAction Ignore
$buildFolder = New-Item -Path $workingDirectory -Name 'publish' -ItemType Directory -Force -ErrorAction Stop
Copy-Item -Path "$workingDirectory/function/*" -Destination $buildFolder.FullName -Recurse -Force

#region Handle Modules
# Process Dependencies
$requiredModules = (Import-PowerShellDataFile -Path "$workingDirectory/BlobToSql/BlobToSql.psd1").RequiredModules
foreach ($module in $requiredModules) {
	if ($module -is [string]) {
		Save-PSFModule -Name $module -Path "$($buildFolder.FullName)/Modules" -Force -Repository $Repository
	}
	else {
		$versionParam = @{}
		if ($module.RequiredVersion) { $versionParam.Version = $module.RequiredVersion }
		elseif ($module.ModuleVersion) { $versionParam.Version = "[$($module.ModuleVersion)-" }
		Save-PSFModule -Name $module.ModuleName @versionParam -Path "$($buildFolder.FullName)/Modules" -Force -Repository $Repository
	}
}

#region Handle the Requirements for Flex Consumption Plans
if ($config.General.FlexConsumption) {
	# Resolve New Dependencies
	$mdepsFile = Join-Path -Path $buildFolder.FullName -ChildPath 'requirements.psd1'
	$mDeps = Import-PowerShellDataFile -Path $mdepsFile
	$requiredModules = foreach ($name in $mDeps.Keys) {
		if ($mDeps.$name -match '\*') {
			@{
				Name    = $name
				Version = '[{0}.0.0-{1}.0.0)' -f $mDeps.$name.Split('.')[0], (1 + $mDeps.$name.Split('.')[0])
			}
		}
		else {
			@{
				Name    = $name
				Version = $mDeps.$name
			}
		}
	}

	# Inject New Dependencies
	foreach ($module in $requiredModules) {
		Save-PSFModule @module -Path "$($buildFolder.FullName)/Modules" -Force -Repository $Repository
	}

	# Disable Managed Dependencies
	$hostFile = Join-Path -Path $buildFolder.FullName -ChildPath 'host.json'
	$hostCfg = Get-Content -Path $hostFile | ConvertFrom-Json
	$hostCfg.managedDependency.enabled = $false
	$hostCfg | ConvertTo-Json -Depth 99 | Set-Content -Path $hostFile
}
#endregion Handle the Requirements for Flex Consumption Plans

# Process Function Module
Copy-Item -Path "$workingDirectory/BlobToSql" -Destination "$($buildFolder.FullName)/Modules" -Force -Recurse
$commands = Get-ChildItem -Path "$($buildFolder.FullName)/Modules/BlobToSql/functions" -Recurse -Filter *.ps1 | ForEach-Object BaseName
Update-PSFModuleManifest -Path "$($buildFolder.FullName)/Modules/BlobToSql/BlobToSql.psd1" -FunctionsToExport $commands
#endregion Handle Modules

#region Triggers
# Generate Http Trigger
$httpCode = Get-Content -Path "$PSScriptRoot\functionHttp\run.ps1" | Join-String -Separator "`n"
$httpConfig = Get-Content -Path "$PSScriptRoot\functionHttp\function.json" | Join-String -Separator "`n"
foreach ($command in Get-ChildItem -Path "$workingDirectory\BlobToSql\functions\httpTrigger" -Recurse -File -Filter *.ps1) {
	$authLevel = $config.HttpTrigger.AuthLevel
	if ($config.HttpTrigger.AuthLevelOverrides.$($command.BaseName)) {
		$authLevel = $config.HttpTrigger.AuthLevelOverrides.$($command.BaseName)
	}
	$methods = $config.HttpTrigger.Methods
	if ($config.HttpTrigger.MethodOverrides.$($command.BaseName)) {
		$methods = $config.HttpTrigger.MethodOverrides.$($command.BaseName)
	}
	$endpointFolder = New-Item -Path $buildFolder.FullName -Name $command.BaseName -ItemType Directory
	$httpCode -replace '%COMMAND%', $command.BaseName | Set-Content -Path "$($endpointFolder.FullName)\run.ps1"
	$httpConfig -replace '%AUTHLEVEL%', $authLevel -replace '%METHODS%', ($methods -join '", "') | Set-Content -Path "$($endpointFolder.FullName)\function.json"
}


# Generate Event Grid Trigger
$eventGridCode = Get-Content -Path "$PSScriptRoot\functionEventGrid\run.ps1" | Join-String -Separator "`n"
$eventGridConfig = Get-Content -Path "$PSScriptRoot\functionEventGrid\function.json" | Join-String -Separator "`n"
foreach ($command in Get-ChildItem -Path "$workingDirectory\BlobToSql\functions\eventGridTrigger" -Recurse -File -Filter *.ps1) {
	$authLevel = $config.EventGridTrigger.AuthLevel
	if ($config.EventGridTrigger.AuthLevelOverrides.$($command.BaseName)) {
		$authLevel = $config.EventGridTrigger.AuthLevelOverrides.$($command.BaseName)
	}
	$methods = $config.EventGridTrigger.Methods
	if ($config.EventGridTrigger.MethodOverrides.$($command.BaseName)) {
		$methods = $config.EventGridTrigger.MethodOverrides.$($command.BaseName)
	}
	$endpointFolder = New-Item -Path $buildFolder.FullName -Name $command.BaseName -ItemType Directory
	$eventGridCode -replace '%COMMAND%', $command.BaseName | Set-Content -Path "$($endpointFolder.FullName)\run.ps1"
	$eventGridConfig -replace '%AUTHLEVEL%', $authLevel -replace '%METHODS%', ($methods -join '", "') | Set-Content -Path "$($endpointFolder.FullName)\function.json"
}

# Generate Timer Trigger
$timerCode = Get-Content -Path "$PSScriptRoot\functionTimer\run.ps1" | Join-String -Separator "`n"
$timerConfig = Get-Content -Path "$PSScriptRoot\functionTimer\function.json" | Join-String -Separator "`n"
foreach ($command in Get-ChildItem -Path "$workingDirectory\BlobToSql\functions\timerTrigger" -Recurse -File -Filter *.ps1) {
	$schedule = $config.TimerTrigger.Schedule
	if ($config.TimerTrigger.ScheduleOverrides.$($command.BaseName)) {
		$schedule = $config.TimerTrigger.ScheduleOverrides.$($command.BaseName)
	}
	$endpointFolder = New-Item -Path $buildFolder.FullName -Name $command.BaseName -ItemType Directory
	$timerCode -replace '%COMMAND%', $command.BaseName | Set-Content -Path "$($endpointFolder.FullName)\run.ps1"
	$timerConfig -replace '%SCHEDULE%', $schedule | Set-Content -Path "$($endpointFolder.FullName)\function.json"
}
# Generate Blob Trigger
$blobCode = Get-Content -Path "$PSScriptRoot/functionBlob/run.ps1" | Join-String -Separator "`n"
$blobConfig = Get-Content -Path "$PSScriptRoot/functionBlob/function.json" | Join-String -Separator "`n"
foreach ($command in Get-ChildItem -Path "$workingDirectory/BlobToSql/functions/blobTrigger" -Recurse -File -Filter *.ps1) {
	$path = $config.BlobTrigger.Path
	if ($config.BlobTrigger.PathOverrides.$($command.BaseName)) {
		$path = $config.BlobTrigger.PathOverrides.$($command.BaseName)
	}
	$connection = $config.BlobTrigger.Connection
	if ($config.BlobTrigger.ConnectionOverrides.$($command.BaseName)) {
		$connection = $config.BlobTrigger.ConnectionOverrides.$($command.BaseName)
	}
	$sqlOutput = $config.BlobTrigger.SqlOutput
	if ($config.BlobTrigger.SqlOutputOverrides.$($command.BaseName)) {
		$sqlOutput = $config.BlobTrigger.SqlOutputOverrides.$($command.BaseName)
	}

	$functionConfig = $blobConfig -replace '%PATH%', $path -replace '%CONNECTION%', $connection -replace '%SOURCE%', $config.BlobTrigger.Source | ConvertFrom-Json
	$outputName = ''
	if ($sqlOutput -and $sqlOutput.CommandText) {
		$outputName = $sqlOutput.Name
		$functionConfig.bindings += [PSCustomObject]@{
			name                    = $sqlOutput.Name
			type                    = 'sql'
			direction               = 'out'
			commandText             = $sqlOutput.CommandText
			connectionStringSetting = $sqlOutput.ConnectionStringSetting
		}
	}

	$endpointFolder = New-Item -Path $buildFolder.FullName -Name $command.BaseName -ItemType Directory
	$blobCode -replace '%COMMAND%', $command.BaseName -replace '%OUTPUTBINDING%', $outputName | Set-Content -Path "$($endpointFolder.FullName)/run.ps1"
	$functionConfig | ConvertTo-Json -Depth 10 | Set-Content -Path "$($endpointFolder.FullName)/function.json"
}
#endregion Triggers

# Package & Cleanup
Remove-Item -Path "$workingDirectory/Function.zip" -Recurse -Force -ErrorAction Ignore
Compress-Archive -Path "$($buildFolder.FullName)/*" -DestinationPath "$workingDirectory/Function.zip"
Remove-Item -Path $buildFolder.FullName -Recurse -Force -ErrorAction Ignore

if (-not $AppRg -or -not $AppName) { return }

Write-Host "Publishing Function App to $AppRg/$AppName"
if ($config.General.FlexConsumption) {
	# Flex Consumption: Publish-AzWebApp is not a documented deployment method; use the Azure CLI (One Deploy)
	az functionapp deployment source config-zip --resource-group $AppRg --name $AppName --src "$workingDirectory/Function.zip" --output none
	if ($LASTEXITCODE -ne 0) { throw "az functionapp deployment source config-zip failed with exit code $LASTEXITCODE" }
}
else {
	$null = Publish-AzWebApp -ResourceGroupName $AppRG -Name $AppName -ArchivePath "$workingDirectory/Function.zip" -Confirm:$false -Force
}
Write-Host "Publishing Function App to $AppRg/$AppName - Done"

if (-not $Restart) { return }

Write-Host "Restarting Function App"
$null = Stop-AzWebApp -ResourceGroupName $AppRG -Name $AppName
$null = Start-AzWebApp -ResourceGroupName $AppRG -Name $AppName
Write-Host "Restarting Function App - Done"