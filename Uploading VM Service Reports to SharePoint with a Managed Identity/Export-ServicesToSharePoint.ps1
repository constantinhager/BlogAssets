<#
.SYNOPSIS
    Exports all Windows services from this virtual machine and uploads the report to SharePoint
    through a Microsoft Graph upload session using a managed identity.

.DESCRIPTION
    Authentication primarily uses the EntraAuth module (Friedrich Weinmann,
    https://github.com/FriedrichWeinmann/EntraAuth), without a client secret or certificate.

    If Connect-EntraService -Identity fails on this virtual machine, for example with
    "Cannot identify a Managed Identity", the script automatically falls back to Microsoft's
    documented direct Azure Instance Metadata Service (IMDS) endpoint at 169.254.169.254.
    EntraAuth's identity detection appears to primarily target the environment variables set by
    Azure Functions and App Service (IDENTITY_ENDPOINT and IDENTITY_HEADER). A standard Azure VM
    does not provide these variables and exposes the managed identity through IMDS instead. This
    fallback allows the script to work in both environments without relying on EntraAuth's
    internal identity-detection logic.

    The script performs the following steps:
    1. Collects all services with Get-Service and writes them to a local CSV file.
    2. Authenticates with the virtual machine's managed identity through EntraAuth, with an
       automatic IMDS fallback.
    3. Resolves the SharePoint site from its URL; no manual site ID lookup is required.
    4. Creates an upload session through /drive/root:/{path}:/createUploadSession and uploads the
       file in 320 KiB blocks with PUT requests directly to the pre-authorized upload URL returned
       by Microsoft Graph. This also supports files larger than 4 MB, which cannot be uploaded by
       a direct PUT request to /content.

.PARAMETER SiteUrl
    The full URL of the SharePoint site, for example
    "https://contoso.sharepoint.com/sites/IT-Reports".

.PARAMETER TargetPath
    The path and file name within the document library. Defaults to
    "Reports/VM01-Services.csv".

.PARAMETER LocalFilePath
    The local path used to store the report before uploading it. Defaults to
    "C:\Reports\VM01-Services.csv".

.PARAMETER ManagedIdentityClientId
    The client ID of a user-assigned managed identity. Leave empty to use the virtual machine's
    system-assigned managed identity.

.PARAMETER ChunkSize
    The upload block size in bytes. Microsoft Graph requires this value to be a multiple of
    320 KiB. The default is approximately 3.2 MB.

.PARAMETER ForceImdsFallback
    Bypasses EntraAuth and obtains the managed identity token directly from IMDS. Useful for
    testing the fallback path.

.EXAMPLE
    $Params = @{
        SiteUrl       = 'https://contoso.sharepoint.com/sites/IT-Reports'
        LocalFilePath = 'C:\Reports\VM01-Services.csv'
    }
    .\Export-ServicesToSharePoint.ps1 @Params

    Exports the services and uploads the report using the system-assigned managed identity.

.EXAMPLE
    $Params = @{
        SiteUrl               = 'https://contoso.sharepoint.com/sites/IT-Reports'
        ManagedIdentityClientId = '11111111-2222-3333-4444-555555555555'
        ForceImdsFallback     = $true
    }
    .\Export-ServicesToSharePoint.ps1 @Params

    Uploads the report with a user-assigned managed identity while explicitly testing IMDS.

.NOTES
    Prerequisites:
    - The EntraAuth module is installed with Install-Module EntraAuth -Scope AllUsers. It is only
      required for the preferred authentication path; the IMDS fallback does not require it.
    - VM01 has a system-assigned or user-assigned managed identity enabled.
    - The managed identity has a Microsoft Graph application permission in the tenant. Sites.Selected
      is recommended and must be granted for the specific SharePoint site. See the related
      Set-SharePointSitePermissionForManagedIdentity.ps1 script.
    - The target directory (document library) already exists in SharePoint.

    Author: Constantin Hager (the-itguy.de)
#>

[CmdletBinding()]
param(
    # Full SharePoint site URL, for example "https://contoso.sharepoint.com/sites/IT-Reports"
    [Parameter(Mandatory)]
    [string]
    $SiteUrl,

    # Path and file name within the document library (the default library is "Documents")
    [Parameter()]
    [string]
    $TargetPath = 'Reports/VM01-Services.csv',

    # Local path used to store the report temporarily
    [Parameter()]
    [string]
    $LocalFilePath = 'C:\Reports\VM01-Services.csv',

    # Client ID of the user-assigned managed identity. Leave empty to use the VM's system-assigned
    # managed identity.
    [Parameter()]
    [string]
    $ManagedIdentityClientId,

    # Upload chunk size; must be a multiple of 320 KiB as required by Microsoft Graph.
    [Parameter()]
    [int64]
    $ChunkSize = 320KB * 10,   # Approximately 3.2 MB per block

    # Forces the IMDS fallback even when EntraAuth is installed; useful for testing.
    [switch]
    $ForceImdsFallback
)

$ErrorActionPreference = 'Stop'
$graphBaseUri = 'https://graph.microsoft.com/v1.0'

function Get-ServicesReport {
    <#
    .SYNOPSIS
        Creates a CSV report of the Windows services on the local computer.

    .DESCRIPTION
        Ensures that the destination directory exists, collects the service name, display name,
        status, and startup type, sorts the entries by name, and exports them as a UTF-8 CSV file.

    .PARAMETER Path
        The local path of the CSV file to create.

    .OUTPUTS
        System.String

    .EXAMPLE
        Get-ServicesReport -Path 'C:\Reports\VM01-Services.csv'

        Creates the services report and returns its path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]
        $Path
    )

    $folder = Split-Path -Path $Path -Parent
    if ($folder -and -not (Test-Path -Path $folder)) {
        New-Item -Path $folder -ItemType Directory -Force | Out-Null
    }

    Get-Service |
    Select-Object -Property Name, DisplayName, Status, StartType |
    Sort-Object -Property Name |
    Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8

    Write-Verbose "Dienste-Report geschrieben nach '$Path'."
    return $Path
}

function Get-ManagedIdentityAccessTokenViaImds {
    <#
    .SYNOPSIS
        Obtains a managed identity access token directly from the Azure Instance Metadata Service.

    .DESCRIPTION
        Uses Microsoft's documented IMDS endpoint for managed identities on Azure virtual machines.
        The request deliberately bypasses any configured system proxy because 169.254.169.254 is a
        link-local address inside the virtual machine and must not be routed through a proxy.

    .PARAMETER Resource
        The resource for which the access token is requested. Defaults to the Microsoft Graph
        resource.

    .PARAMETER ClientId
        The client ID of a user-assigned managed identity. Omit this parameter for a
        system-assigned managed identity.

    .OUTPUTS
        System.String

    .EXAMPLE
        Get-ManagedIdentityAccessTokenViaImds -ClientId $managedIdentityClientId

        Requests a Microsoft Graph access token for a user-assigned managed identity.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]
        $Resource = 'https://graph.microsoft.com/',

        [Parameter()]
        [string]
        $ClientId
    )

    $imdsUri = 'http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource={0}' -f `
        [uri]::EscapeDataString($Resource)
    if ($ClientId) { $imdsUri += "&client_id=$ClientId" }

    $request = [System.Net.WebRequest]::Create($imdsUri)
    $request.Proxy = $null
    $request.Headers.Add('Metadata', 'true')
    $request.Method = 'GET'

    try {
        $response = $request.GetResponse()
    } catch [System.Net.WebException] {
        throw "IMDS token request failed: $($_.Exception.Message). Is this script running on an Azure VM with a managed identity enabled?"
    }

    try {
        $stream = $response.GetResponseStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $json = $reader.ReadToEnd() | ConvertFrom-Json
    } finally {
        $reader.Dispose()
        $response.Dispose()
    }

    return $json.access_token
}

function Connect-ManagedIdentity {
    <#
    .SYNOPSIS
        Connects through EntraAuth or obtains a managed identity token through IMDS.

    .DESCRIPTION
        Attempts to connect with EntraAuth first. If EntraAuth cannot identify the managed
        identity, the function automatically obtains a token directly from IMDS. When EntraAuth
        succeeds, the function returns null and Invoke-EntraRequest can be used normally. When
        the IMDS fallback is used, the function returns the raw access token for use in an
        Authorization header.

    .PARAMETER ManagedIdentityClientId
        The client ID of a user-assigned managed identity. Omit this parameter for a
        system-assigned managed identity.

    .PARAMETER ForceImdsFallback
        Skips EntraAuth and always obtains the token directly from IMDS.

    .OUTPUTS
        System.String

    .EXAMPLE
        $accessToken = Connect-ManagedIdentity

        Uses EntraAuth when available and falls back to IMDS when necessary.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]
        $ManagedIdentityClientId,

        [Parameter()]
        [switch]
        $ForceImdsFallback
    )

    $entraAuthAvailable = -not $ForceImdsFallback -and (Get-Module -ListAvailable -Name EntraAuth)

    if ($entraAuthAvailable) {
        try {
            if ($ManagedIdentityClientId) {
                Connect-EntraService -Identity -IdentityID $ManagedIdentityClientId
            } else {
                Connect-EntraService -Identity
            }
            Write-Verbose 'Authenticated successfully through EntraAuth.'
            return $null
        } catch {
            Write-Warning "Connect-EntraService -Identity failed ($($_.Exception.Message)). Falling back to a direct IMDS token request."
        }
    } else {
        Write-Verbose 'EntraAuth was not used (not installed or -ForceImdsFallback was specified); using a direct IMDS token request.'
    }

    return Get-ManagedIdentityAccessTokenViaImds -ClientId $ManagedIdentityClientId
}

function Invoke-GraphRequest {
    <#
    .SYNOPSIS
        Sends a Microsoft Graph request through EntraAuth or with an explicit access token.

    .DESCRIPTION
        Uses Invoke-EntraRequest when an EntraAuth session is available. When an IMDS token is
        supplied, sends the request with Invoke-RestMethod and serializes nested request bodies
        with sufficient JSON depth.

    .PARAMETER Path
        The Microsoft Graph v1.0 path without the service root URL.

    .PARAMETER Method
        The HTTP method. Defaults to GET.

    .PARAMETER Body
        The request body to serialize as JSON.

    .PARAMETER AccessToken
        An optional bearer token obtained through the IMDS fallback.

    .OUTPUTS
        The Microsoft Graph response object.

    .EXAMPLE
        Invoke-GraphRequest -Path 'sites/contoso.sharepoint.com:/sites/Reports'

        Retrieves a SharePoint site through the active EntraAuth session.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]
        $Path,

        [Parameter()]
        [string]
        $Method = 'GET',

        [Parameter()]
        [object]
        $Body,

        [Parameter()]
        [string]
        $AccessToken
    )

    if (-not $AccessToken) {
        $params = @{ Path = $Path }
        if ($Method -ne 'GET') { $params.Method = $Method }
        if ($Body) { $params.Body = $Body }
        return Invoke-EntraRequest @params
    }

    $uri = "$graphBaseUri/$Path"
    $params = @{
        Method  = $Method
        Uri     = $uri
        Headers = @{ Authorization = "Bearer $AccessToken" }
    }

    if ($Body) {
        $params.ContentType = 'application/json'
        $params.Body = ($Body | ConvertTo-Json -Depth 10 -Compress)
    }

    return Invoke-RestMethod @params
}

function Resolve-SharePointSiteId {
    <#
    .SYNOPSIS
        Resolves a SharePoint site URL to its Microsoft Graph site ID.

    .DESCRIPTION
        Converts the host name and path from a SharePoint URL into the Microsoft Graph site
        addressing format and retrieves the corresponding site resource.

    .PARAMETER SiteUrl
        The full URL of the SharePoint site to resolve.

    .PARAMETER AccessToken
        An optional bearer token obtained through the IMDS fallback.

    .OUTPUTS
        System.String

    .EXAMPLE
        Resolve-SharePointSiteId -SiteUrl 'https://contoso.sharepoint.com/sites/IT-Reports'

        Returns the Graph site ID for the specified SharePoint site.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]
        $SiteUrl,

        [Parameter()]
        [string]
        $AccessToken
    )

    $uri = [uri] $SiteUrl
    $hostname = $uri.Host
    $sitePath = $uri.AbsolutePath.Trim('/')

    $graphPath = if ($sitePath) { "sites/${hostname}:/${sitePath}" } else { "sites/${hostname}" }

    $site = Invoke-GraphRequest -Path $graphPath -AccessToken $AccessToken
    if (-not $site.id) {
        throw "Could not resolve site '$SiteUrl'; the response did not contain an 'id' property."
    }
    return $site.id
}

function Send-FileToSharePointViaUploadSession {
    <#
    .SYNOPSIS
        Uploads a local file to SharePoint through a Microsoft Graph upload session.

    .DESCRIPTION
        Creates or replaces the target file and uploads it in chunks. The upload URL returned by
        Microsoft Graph is used directly without an Authorization header. If a chunk upload
        fails, the upload session is deleted when possible so that a retry is not blocked by a
        stale session.

    .PARAMETER SiteId
        The Microsoft Graph ID of the SharePoint site.

    .PARAMETER TargetPath
        The path and file name of the target file in the document library.

    .PARAMETER LocalFilePath
        The local path of the file to upload.

    .PARAMETER ChunkSize
        The number of bytes sent in each upload request. Microsoft Graph requires a multiple of
        320 KiB for all chunks except the final chunk.

    .PARAMETER AccessToken
        An optional bearer token obtained through the IMDS fallback.

    .OUTPUTS
        The final response returned by Microsoft Graph after the upload.

    .EXAMPLE
        Send-FileToSharePointViaUploadSession -SiteId $siteId `
            -TargetPath 'Reports/VM01-Services.csv' `
            -LocalFilePath 'C:\Reports\VM01-Services.csv' `
            -ChunkSize (320KB * 10)

        Uploads the local report to the specified SharePoint path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]
        $SiteId,

        [Parameter(Mandatory)]
        [string]
        $TargetPath,

        [Parameter(Mandatory)]
        [string]
        $LocalFilePath,

        [Parameter(Mandatory)]
        [int64]
        $ChunkSize,

        [Parameter()]
        [string]
        $AccessToken
    )

    $encodedPath = ($TargetPath -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'

    # 1) Create the upload session.
    $sessionBody = @{
        item = @{
            '@microsoft.graph.conflictBehavior' = 'replace'
        }
    }

    $Parameters = @{
        Method      = 'Post'
        Path        = "sites/$SiteId/drive/root:/${encodedPath}:/createUploadSession"
        Body        = $sessionBody
        AccessToken = $AccessToken
    }
    $session = Invoke-GraphRequest @Parameters

    # 2) Send the file in chunks to the pre-authorized upload URL. Do not send an Authorization
    #    header to the upload URL itself; this is required by Microsoft Graph.
    $fileStream = [System.IO.File]::OpenRead($LocalFilePath)
    $totalSize = $fileStream.Length
    $buffer = New-Object byte[] $ChunkSize
    $offset = 0
    $lastResponse = $null

    try {
        while ($offset -lt $totalSize) {
            $bytesRead = $fileStream.Read($buffer, 0, $buffer.Length)
            if ($bytesRead -eq $buffer.Length) {
                $chunk = $buffer
            } else {
                $chunk = New-Object byte[] $bytesRead
                [System.Array]::Copy($buffer, $chunk, $bytesRead)
            }
            $rangeEnd = $offset + $bytesRead - 1

            $parameters = @{
                Method      = 'Put'
                Uri         = $session.uploadUrl
                Headers     = @{
                    'Content-Range' = "bytes $offset-$rangeEnd/$totalSize"
                }
                ContentType = 'application/octet-stream'
                Body        = $chunk
            }
            $lastResponse = Invoke-RestMethod @parameters

            Write-Verbose "Uploaded block $offset-$rangeEnd of $totalSize."
            $offset += $bytesRead
        }
    } catch {
        if ($session.uploadUrl) {
            try {
                Invoke-RestMethod -Method Delete -Uri $session.uploadUrl -ErrorAction SilentlyContinue | Out-Null
                Write-Verbose 'The incomplete upload session was terminated.'
            } catch {
                Write-Verbose 'The incomplete upload session could not be terminated.'
            }
        }
        throw
    } finally {
        $fileStream.Dispose()
    }

    return $lastResponse
}

# --- Execution ---

Write-Verbose 'Collecting services...'
$reportPath = Get-ServicesReport -Path $LocalFilePath

Write-Verbose 'Authenticating with the managed identity...'
$Parameters = @{
    ManagedIdentityClientId = $ManagedIdentityClientId
    ForceImdsFallback       = $ForceImdsFallback
}
$manualAccessToken = Connect-ManagedIdentity @Parameters

Write-Verbose "Resolving site URL '$SiteUrl'..."
$siteId = Resolve-SharePointSiteId -SiteUrl $SiteUrl -AccessToken $manualAccessToken

Write-Verbose "Uploading '$reportPath' to SharePoint through an upload session ($TargetPath)..."
$Parameters = @{
    SiteId        = $siteId
    TargetPath    = $TargetPath
    LocalFilePath = $reportPath
    ChunkSize     = $ChunkSize
    AccessToken   = $manualAccessToken
}
$uploadResult = Send-FileToSharePointViaUploadSession @Parameters

Write-Host "Upload completed successfully: $($uploadResult.webUrl)"
