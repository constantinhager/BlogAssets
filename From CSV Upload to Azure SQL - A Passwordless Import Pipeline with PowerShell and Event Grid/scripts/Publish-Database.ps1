<#
.SYNOPSIS
    Deploys the SQL database project (dacpac) with SqlPackage, or previews the changes.

.DESCRIPTION
    Uses database/BlobToSqlDb/BlobToSqlDb.publish.xml for the publish options.
    Authenticates with an Entra access token (you or the CI service principal must be in the
    SQL admin group). The caller's public IP must be allowed on the SQL firewall.

    Actions:
    - Publish       apply the schema, then run the post-deployment script (user + role membership)
    - Script        write the T-SQL that Publish would run (review / PR preview)
    - DeployReport  write an XML report of the changes

.PARAMETER SqlServerFqdn
    Fully qualified name of the Azure SQL server, for example <server>.database.windows.net.
    Terraform output: sql_server_fqdn.

.PARAMETER Database
    Name of the target database on that server. Terraform output: sql_database.

.PARAMETER IdentityName
    Name of the Function App's user-assigned managed identity. Passed to the post-deployment
    script as the SqlCmd variable IdentityName; it becomes the database user name that is added
    to the app_importer role. Terraform output: sql_identity_name.

.PARAMETER IdentityClientId
    Client ID of that managed identity. Passed as the SqlCmd variable IdentityClientId; the
    post-deployment script derives the user's SID from it, so no Microsoft Graph lookup is needed.
    Terraform output: sql_identity_client_id.

.PARAMETER Action
    SqlPackage action to run: Publish, Script or DeployReport (see the description). Default: Publish.

.PARAMETER DacpacPath
    Path to the built dacpac. Default: builds database/BlobToSqlDb with dotnet build and uses its output.

.PARAMETER OutputPath
    File for the output of Script (T-SQL) or DeployReport (XML). Ignored for Publish.
    Default: db-script.sql or db-deployreport.xml in the current directory.

.PARAMETER AccessToken
    Token for https://database.windows.net/. If omitted, taken from Az.Accounts or the Azure CLI.

.PARAMETER MaxAttempts
    How often sqlpackage is tried before the script fails, with 20 seconds between attempts.
    Covers new firewall rules and group memberships that take a moment to apply. Default: 4.

.EXAMPLE
    Set-Location ./infra
    ../scripts/Publish-Database.ps1 `
        -SqlServerFqdn    (terraform output -raw sql_server_fqdn) `
        -Database         (terraform output -raw sql_database) `
        -IdentityName     (terraform output -raw sql_identity_name) `
        -IdentityClientId (terraform output -raw sql_identity_client_id)

.EXAMPLE
    ../scripts/Publish-Database.ps1 -Action Script -OutputPath ./db-changes.sql ...

    Writes the deployment script without changing the database.
#>
#Requires -Version 7.2
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string]
    $SqlServerFqdn,

    [Parameter(Mandatory)]
    [string]
    $Database,

    [Parameter(Mandatory)]
    [string]
    $IdentityName,

    [Parameter(Mandatory)]
    [guid]
    $IdentityClientId,

    [ValidateSet('Publish', 'Script', 'DeployReport')]
    [string]
    $Action = 'Publish',

    [string]
    $DacpacPath,

    [string]
    $OutputPath,

    [string]
    $AccessToken,

    [int]
    $MaxAttempts = 4
)

$ErrorActionPreference = 'Stop'
$projectDir = Join-Path $PSScriptRoot '..' 'database' 'BlobToSqlDb' | Resolve-Path
$profilePath = Join-Path $projectDir 'BlobToSqlDb.publish.xml'

#region Tools
$sqlpackage = Get-Command sqlpackage -ErrorAction Ignore
if (-not $sqlpackage) {
    throw 'sqlpackage not found. Install it with: dotnet tool install -g microsoft.sqlpackage'
}

if (-not $DacpacPath) {
    Write-Host "Building $projectDir ..."
    dotnet build (Join-Path $projectDir 'BlobToSqlDb.sqlproj') --configuration Release
    if ($LASTEXITCODE -ne 0) { throw 'dotnet build of the database project failed.' }
    $DacpacPath = Join-Path $projectDir 'bin' 'Release' 'BlobToSqlDb.dacpac'
}
if (-not (Test-Path $DacpacPath)) { throw "Dacpac not found: $DacpacPath" }
#endregion Tools

#region Token
if (-not $AccessToken) {
    if (Get-Command Get-AzAccessToken -ErrorAction Ignore) {
        $tok = Get-AzAccessToken -ResourceUrl 'https://database.windows.net/'
        $AccessToken = if ($tok.Token -is [securestring]) { $tok.Token | ConvertFrom-SecureString -AsPlainText } else { $tok.Token }
    }
    else {
        $AccessToken = az account get-access-token --resource https://database.windows.net/ --query accessToken --output tsv
        if ($LASTEXITCODE -ne 0 -or -not $AccessToken) { throw 'Could not get a SQL access token. Log in with Connect-AzAccount or az login.' }
    }
}
#endregion Token

$arguments = @(
    "/Action:$Action"
    "/SourceFile:$DacpacPath"
    "/Profile:$profilePath"
    "/TargetServerName:$SqlServerFqdn"
    "/TargetDatabaseName:$Database"
    "/AccessToken:$AccessToken"
    "/Variables:IdentityName=$IdentityName"
    "/Variables:IdentityClientId=$IdentityClientId"
)
if ($Action -ne 'Publish') {
    if (-not $OutputPath) { $OutputPath = Join-Path (Get-Location) ("db-{0}.{1}" -f $Action.ToLower(), $(if ($Action -eq 'Script') { 'sql' } else { 'xml' })) }
    $arguments += "/OutputPath:$OutputPath"
}

# New firewall rules and group memberships can take a moment to apply
for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    Write-Host "sqlpackage /Action:$Action -> $SqlServerFqdn/$Database (attempt $attempt/$MaxAttempts)"
    & $sqlpackage.Source @arguments
    if ($LASTEXITCODE -eq 0) { break }
    if ($attempt -eq $MaxAttempts) { throw "sqlpackage /Action:$Action failed with exit code $LASTEXITCODE" }
    Write-Warning "sqlpackage failed with exit code $LASTEXITCODE. Retrying in 20 s."
    Start-Sleep -Seconds 20
}

if ($OutputPath) { Write-Host "Output: $OutputPath" }
