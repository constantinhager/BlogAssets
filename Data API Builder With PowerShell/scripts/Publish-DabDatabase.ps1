#Requires -Version 7.4
<#
.SYNOPSIS
    Publishes the MeetupDb .dacpac to Azure SQL with SqlPackage and an Entra ID token.

.DESCRIPTION
    SqlPackage compares the .dacpac (built from database/MeetupDb.sqlproj) with the target
    database and applies only the difference. The post-deployment script then creates the
    database user of the DAB managed identity and inserts the sample data - both idempotent.

    The token comes from -AccessToken, from the Azure CLI (az account get-access-token) or from
    Az.Accounts (Get-AzAccessToken), in this order. The caller must be a member of the SQL
    server's Microsoft Entra admin group. No SQL login, no password.

    -Action Script or DeployReport writes the T-SQL or the change report to -OutputPath
    instead of changing the database.

    Requires SqlPackage: dotnet tool install --global microsoft.sqlpackage

.EXAMPLE
    # Locally, after az login or Connect-AzAccount, with your public IP in the SQL firewall:
    dotnet build ./database/MeetupDb.sqlproj --configuration Release
    $db = @{
        DacpacPath          = './database/bin/Release/MeetupDb.dacpac'
        ServerName          = (terraform -chdir=infra output -raw sql_server_fqdn)
        DatabaseName        = (terraform -chdir=infra output -raw database_name)
        DabIdentityName     = (terraform -chdir=infra output -raw dab_identity_name)
        DabIdentityClientId = (terraform -chdir=infra output -raw dab_identity_client_id)
    }
    ./scripts/Publish-DabDatabase.ps1 @db -Action DeployReport -OutputPath ./out
    ./scripts/Publish-DabDatabase.ps1 @db
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The Azure CLI returns the token as plain text. Wrapping it right away keeps it out of variables and logs.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string] $DacpacPath,

    [Parameter(Mandatory)]
    [string] $ServerName,

    [Parameter(Mandatory)]
    [string] $DatabaseName,

    [Parameter(Mandatory)]
    [string] $DabIdentityName,

    # Client ID of the user-assigned managed identity (not the principal ID).
    [Parameter(Mandatory)]
    [guid] $DabIdentityClientId,

    [ValidateSet('Publish', 'Script', 'DeployReport')]
    [string] $Action = 'Publish',

    [string] $OutputPath = (Join-Path -Path (Get-Location) -ChildPath 'out'),

    [securestring] $AccessToken,

    [ValidateRange(1, 10)]
    [int] $MaxAttempts = 5
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command sqlpackage -ErrorAction SilentlyContinue)) {
    throw 'SqlPackage not found. Install it with: dotnet tool install --global microsoft.sqlpackage'
}

function Get-SqlAccessToken {
    <#
        .SYNOPSIS
        Gets an access token for Azure SQL Database.

        .DESCRIPTION
        Requests a token for https://database.windows.net/ from the Azure CLI first,
        then from Az.Accounts. Throws when neither is signed in.

        .OUTPUTS
        System.Security.SecureString
        Returns the access token.

        .EXAMPLE
        $AccessToken = Get-SqlAccessToken
    #>

    [OutputType([System.Security.SecureString])]
    param()

    $resource = 'https://database.windows.net/'
    if (Get-Command az -ErrorAction SilentlyContinue) {
        $plain = az account get-access-token --resource $resource --query accessToken --output tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and $plain) {
            return ConvertTo-SecureString -String $plain -AsPlainText -Force
        }
    }
    if (Get-Command Get-AzAccessToken -ErrorAction SilentlyContinue) {
        return (Get-AzAccessToken -ResourceUrl $resource).Token   # SecureString in Az.Accounts 5+
    }
    throw 'No token: sign in with az login or Connect-AzAccount, or pass -AccessToken.'
}

if (-not $AccessToken) { $AccessToken = Get-SqlAccessToken }

$arguments = @(
    "/Action:$Action"
    "/SourceFile:$((Resolve-Path -Path $DacpacPath).Path)"
    "/TargetServerName:$ServerName"
    "/TargetDatabaseName:$DatabaseName"
    "/Variables:DabIdentityName=$DabIdentityName"
    "/Variables:DabIdentityClientId=$DabIdentityClientId"
    # Terraform owns the database settings (SKU S0, collation, options) - SqlPackage only the schema.
    '/p:ScriptDatabaseOptions=False'
    '/p:BlockOnPossibleDataLoss=True'
    '/p:DropObjectsNotInSource=False'
)
switch ($Action) {
    'Script' {
        $null = New-Item -Path $OutputPath -ItemType Directory -Force
        $arguments += "/OutputPath:$(Join-Path -Path $OutputPath -ChildPath "$DatabaseName.publish.sql")"
    }
    'DeployReport' {
        $null = New-Item -Path $OutputPath -ItemType Directory -Force
        $arguments += "/OutputPath:$(Join-Path -Path $OutputPath -ChildPath "$DatabaseName.deployreport.xml")"
    }
}

# A new firewall rule needs a moment until it is active. Retry connection errors only.
$transient = 'Unable to connect|Cannot open server|40615|40613|A network-related|timeout'
foreach ($attempt in 1..$MaxAttempts) {
    # The token goes to SqlPackage as an argument - it never lands in a variable that gets logged.
    $output = & sqlpackage @arguments "/AccessToken:$(ConvertFrom-SecureString -SecureString $AccessToken -AsPlainText)" 2>&1
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-Verbose "$_" }

    if ($exitCode -eq 0) {
        $output | Select-Object -Last 5
        if ($Action -ne 'Publish') { Write-Output "Written to $OutputPath" }
        return
    }
    if ($attempt -lt $MaxAttempts -and ($output -join "`n") -match $transient) {
        Write-Warning "SqlPackage could not connect (attempt $attempt of $MaxAttempts). Retrying in 20 seconds."
        Start-Sleep -Seconds 20
        continue
    }
    $output | Write-Output
    throw "SqlPackage $Action failed with exit code $exitCode."
}
