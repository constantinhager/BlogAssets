#Requires -Version 7.2
<#
.SYNOPSIS
    Runs Import-CsvBlob against the sample files, without Azure.
.EXAMPLE
    ./tests/Invoke-LocalTest.ps1
#>
[CmdletBinding()]
param ()

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../BlobToSql/BlobToSql.psd1" -Force

function Invoke-Case {
    param ($File, [hashtable] $Environment = @{}, [switch] $ExpectFailure)

    $saved = @{}
    foreach ($key in $Environment.Keys) { $saved[$key] = [Environment]::GetEnvironmentVariable($key); [Environment]::SetEnvironmentVariable($key, $Environment[$key]) }
    try {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $File))
        $rows = Import-CsvBlob -InputBlob $bytes -BlobName $File
        if ($ExpectFailure) { Write-Host "FAIL  $File - expected an error" -ForegroundColor Red; $script:failed++ ; return }
        Write-Host "PASS  $File - $(@($rows).Count) row(s)" -ForegroundColor Green
        $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    }
    catch {
        if ($ExpectFailure) { Write-Host "PASS  $File - rejected as expected:`n$($_.Exception.Message)`n" -ForegroundColor Green; return }
        Write-Host "FAIL  $File - $_" -ForegroundColor Red; $script:failed++
    }
    finally {
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key, $saved[$key]) }
    }
}

$script:failed = 0
Invoke-Case -File 'sample-semicolon.csv' -Environment @{ CSV_SOURCE_TIMEZONE = 'Europe/Berlin' }
Invoke-Case -File 'sample-comma.csv'
Invoke-Case -File 'sample-ansi.csv' -Environment @{ CSV_ENCODING = 'windows-1252' }
Invoke-Case -File 'sample-invalid.csv' -ExpectFailure

if ($script:failed) { throw "$script:failed case(s) failed" }
