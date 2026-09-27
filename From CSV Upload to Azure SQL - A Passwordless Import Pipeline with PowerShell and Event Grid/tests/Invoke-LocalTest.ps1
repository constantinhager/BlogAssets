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
    param (
        $File,

        [hashtable]
        $Environment = @{},

        # DeviceId values the rows must contain, in order (checks decoding, e.g. umlauts)
        [string[]]
        $ExpectDeviceId,

        [switch]
        $ExpectFailure
    )

    $saved = @{}
    foreach ($key in $Environment.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key)
        [Environment]::SetEnvironmentVariable($key, $Environment[$key])
    }
    try {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $File))
        $rows = Import-CsvBlob -InputBlob $bytes -BlobName $File
        if ($ExpectFailure) {
            Write-Host "FAIL  $File - expected an error" -ForegroundColor Red
            $script:failed++
            return
        }
        $deviceIds = @($rows.DeviceId)
        if ($ExpectDeviceId -and (Compare-Object -ReferenceObject $ExpectDeviceId -DifferenceObject $deviceIds -SyncWindow 0 -CaseSensitive)) {
            Write-Host "FAIL  $File - DeviceId '$($deviceIds -join "', '")', expected '$($ExpectDeviceId -join "', '")'" -ForegroundColor Red
            $script:failed++
            return
        }
        Write-Host "PASS  $File - $(@($rows).Count) row(s)" -ForegroundColor Green
        $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
    } catch {
        if ($ExpectFailure) {
            Write-Host "PASS  $File - rejected as expected:`n$($_.Exception.Message)`n" -ForegroundColor Green
            return
        }
        Write-Host "FAIL  $File - $_" -ForegroundColor Red
        $script:failed++
    } finally {
        foreach ($key in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($key, $saved[$key])
        }
    }
}

$script:failed = 0
Invoke-Case -File 'sample-semicolon.csv' -Environment @{ CSV_SOURCE_TIMEZONE = 'Europe/Berlin' }
Invoke-Case -File 'sample-comma.csv'
# CSV_ENCODING = auto (default) detects windows-1252 and UTF-8; a fixed setting still works
Invoke-Case -File 'sample-ansi.csv' -Environment @{ CSV_ENCODING = '' } -ExpectDeviceId 'Kühlraum-Süd'
Invoke-Case -File 'sample-utf8.csv' -Environment @{ CSV_ENCODING = '' } -ExpectDeviceId 'Kühlraum-Süd', 'Außenlager-Öltank'
Invoke-Case -File 'sample-ansi.csv' -Environment @{ CSV_ENCODING = 'windows-1252' } -ExpectDeviceId 'Kühlraum-Süd'
Invoke-Case -File 'sample-invalid.csv' -ExpectFailure

if ($script:failed) {
    throw "$script:failed case(s) failed"
}
