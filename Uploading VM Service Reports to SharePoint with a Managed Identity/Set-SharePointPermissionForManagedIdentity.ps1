<#
.SYNOPSIS
    Configures SharePoint access for a managed identity by assigning the Microsoft Graph
    application permission "Sites.Selected" and granting the identity a role on one SharePoint
    site (read/write/owner).

.DESCRIPTION
    This script is intended to be run ONCE by an administrator, not by the virtual machine itself.
    A managed identity cannot grant this permission to itself.

    The script performs the following steps:
    1. Signs in an administrator interactively through EntraAuth (delegated), requesting
       Application.Read.All, AppRoleAssignment.ReadWrite.All, and Sites.FullControl.All.
    2. Resolves the managed identity to a service principal by object ID or display name.
    3. Assigns the Microsoft Graph application permission "Sites.Selected" to the service
       principal if it has not already been assigned.
    4. Resolves the SharePoint site from its URL, so the site ID does not need to be determined
       manually.
    5. Uses POST /sites/{site-id}/permissions, or PATCH when an entry already exists, to grant
       the managed identity the requested role (read/write/owner) on THIS SITE ONLY.

.PARAMETER TenantId
    The tenant ID or domain name, for example contoso.onmicrosoft.com, that contains both the
    managed identity and the SharePoint site.

.PARAMETER SiteUrl
    The full URL of the SharePoint site, for example
    "https://contoso.sharepoint.com/sites/IT-Reports".

.PARAMETER ManagedIdentityObjectId
    The object (principal) ID of the managed identity. Alternatively, use
    -ManagedIdentityDisplayName.

.PARAMETER ManagedIdentityDisplayName
    The display name of the managed identity, such as the name of a user-assigned identity or a
    system-assigned identity's virtual machine. Used when -ManagedIdentityObjectId is not
    specified.

.PARAMETER Role
    The permission level on the site: 'read', 'write', or 'owner'. The default is 'write', which
    is suitable for the upload script.

.PARAMETER AdminClientId
    The application (client) ID used for interactive administrator sign-in. By default, the
    public Microsoft Graph PowerShell application ID is used, so no custom app registration is
    required. Specify a different client ID when using a custom app registration.

.EXAMPLE
    .\Set-SharePointSitePermissionForManagedIdentity.ps1 `
        -TenantId 'contoso.onmicrosoft.com' `
        -SiteUrl 'https://contoso.sharepoint.com/sites/IT-Reports' `
        -ManagedIdentityDisplayName 'id-vm01-sharepoint' `
        -Role write

.NOTES
    Requires a Global Administrator or Privileged Role Administrator for the app role assignment,
    and a SharePoint Administrator or Global Administrator for the Sites.FullControl.All
    permission required to set the site permission.

    POST/PATCH requests with deeply nested bodies, such as /sites/{id}/permissions, are sent
    through Invoke-EntraJsonRequest instead of directly through Invoke-EntraRequest. ConvertTo-Json
    serializes only to -Depth 2 by default; Microsoft Graph otherwise returns "Invalid request"
    when nested objects are serialized too shallowly.

    Module: EntraAuth (https://github.com/FriedrichWeinmann/EntraAuth)
    Author: Constantin Hager (the-itguy.de)
#>

[CmdletBinding(DefaultParameterSetName = 'ByObjectId')]
param(
    [Parameter(Mandatory)]
    [string]
    $TenantId,

    [Parameter(Mandatory)]
    [string]
    $SiteUrl,

    [Parameter(Mandatory, ParameterSetName = 'ByObjectId')]
    [string]
    $ManagedIdentityObjectId,

    [Parameter(Mandatory, ParameterSetName = 'ByDisplayName')]
    [string]
    $ManagedIdentityDisplayName,

    [Parameter()]
    [ValidateSet('read', 'write', 'owner')]
    [string]
    $Role = 'write',

    [Parameter()]
    [string]
    $GraphAppRolePermission = 'Sites.Selected',

    [Parameter()]
    [string]
    $AdminClientId = '14d82eec-204b-4c2f-b7e8-296a70dab67e'  # bekannte Microsoft-Graph-PowerShell-App-ID
)

$ErrorActionPreference = 'Stop'

function Get-EntraCollectionValue {
    <#
    .SYNOPSIS
        Returns collection items from either an OData response or an already unwrapped array.

    .DESCRIPTION
        EntraAuth versions may return a Graph collection response with a `.value` property or
        return the collection items directly. This function normalizes both response shapes.

    .PARAMETER Response
        The response returned by a Microsoft Graph request.

    .OUTPUTS
        System.Object[]

    .EXAMPLE
        $items = Get-EntraCollectionValue -Response $response

        Normalizes a Graph collection response before processing its items.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Response
    )

    if ($null -eq $Response) {
        return @()
    }

    if ($Response.PSObject.Properties.Match('value').Count -gt 0) {
        return @($Response.value)
    }

    return @($Response)
}

function Invoke-EntraJsonRequest {
    <#
    .SYNOPSIS
        Sends an authenticated Microsoft Graph request with a JSON request body.

    .DESCRIPTION
        Sends POST or PATCH requests through Invoke-RestMethod while using the token managed by
        EntraAuth. The request body is serialized with sufficient depth for nested Graph objects.

    .PARAMETER Method
        The HTTP method, such as `Post` or `Patch`.

    .PARAMETER Path
        The Microsoft Graph v1.0 path without the service root URL.

    .PARAMETER Body
        The request body to serialize as JSON.

    .PARAMETER Service
        The EntraAuth service used to obtain the access token. Defaults to `Graph`.

    .OUTPUTS
        The response returned by Invoke-RestMethod.

    .EXAMPLE
        Invoke-EntraJsonRequest -Method Post -Path 'sites/contoso:/sites/Reports:/permissions' -Body $body

        Sends a nested JSON request body to Microsoft Graph.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]
        $Method,

        [Parameter(Mandatory)]
        [string]
        $Path,

        [Parameter(Mandatory)]
        $Body,

        [Parameter()]
        [string]
        $Service = 'Graph'
    )

    $token = Get-EntraToken -Service $Service
    $uri = "https://graph.microsoft.com/v1.0/$Path"
    $json = $Body | ConvertTo-Json -Depth 10 -Compress

    Write-Verbose "Request-Body: $json"

    Invoke-RestMethod -Method $Method -Uri $uri -Headers $token.GetHeader() `
        -ContentType 'application/json' -Body $json
}

function Connect-AdminSession {
    <#
    .SYNOPSIS
        Connects an administrator to the required Microsoft Graph services.

    .DESCRIPTION
        Establishes an interactive EntraAuth session for the tenant and requests the delegated
        permissions required to resolve service principals, assign Graph app roles, and set a
        SharePoint site permission.

    .PARAMETER TenantId
        The tenant ID or verified tenant domain to connect to.

    .PARAMETER ClientId
        The client ID of the application used for interactive sign-in.

    .EXAMPLE
        Connect-AdminSession -TenantId 'contoso.onmicrosoft.com' -ClientId $clientId

        Starts the administrator sign-in flow for the specified tenant.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]
        $TenantId,

        [Parameter(Mandatory)]
        [string]
        $ClientId
    )

    Connect-EntraService -ClientID $ClientId -TenantID $TenantId -Scopes @(
        'Application.Read.All'
        'AppRoleAssignment.ReadWrite.All'
        'Sites.FullControl.All'
    )
}

function Get-ManagedIdentityServicePrincipal {
    <#
    .SYNOPSIS
        Resolves a managed identity to its Microsoft Graph service principal.

    .DESCRIPTION
        Retrieves a service principal by object ID when one is provided. Otherwise, searches by
        display name and requires exactly one matching service principal.

    .PARAMETER ObjectId
        The object ID of the managed identity service principal.

    .PARAMETER DisplayName
        The display name used to find the managed identity service principal when ObjectId is not
        provided.

    .OUTPUTS
        The Microsoft Graph service principal object.

    .EXAMPLE
        Get-ManagedIdentityServicePrincipal -DisplayName 'id-vm01-sharepoint'

        Resolves a managed identity by display name.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]
        $ObjectId,

        [Parameter(Mandatory)]
        [string]
        $DisplayName
    )

    if ($ObjectId) {
        return Invoke-EntraRequest -Path "servicePrincipals/$ObjectId"
    }

    $filterValue = $DisplayName.Replace("'", "''")
    $result = Invoke-EntraRequest -Path 'servicePrincipals' -Query @{
        '$filter' = "displayName eq '$filterValue'"
    }

    $matches = Get-EntraCollectionValue -Response $result
    if ($matches.Count -eq 0) {
        throw "Kein Service Principal mit Anzeigename '$DisplayName' gefunden. Pruefe die Schreibweise oder verwende -ManagedIdentityObjectId."
    }
    if ($matches.Count -gt 1) {
        throw "Mehr als ein Service Principal mit Anzeigename '$DisplayName' gefunden. Bitte -ManagedIdentityObjectId verwenden."
    }

    $sp = $matches[0]
    if (-not $sp.id) {
        throw "Service Principal fuer '$DisplayName' gefunden, aber ohne 'id'-Eigenschaft zurueckgegeben - unerwartetes Antwortformat von Invoke-EntraRequest."
    }

    return $sp
}

function Grant-GraphAppRoleToServicePrincipal {
    <#
    .SYNOPSIS
        Assigns a Microsoft Graph application permission to a service principal.

    .DESCRIPTION
        Finds the requested application role on the Microsoft Graph service principal and assigns
        it to the target service principal unless the assignment already exists.

    .PARAMETER ServicePrincipalId
        The object ID of the service principal receiving the application permission.

    .PARAMETER AppRoleValue
        The Graph application permission value to assign, such as `Sites.Selected`.

    .EXAMPLE
        Grant-GraphAppRoleToServicePrincipal -ServicePrincipalId $servicePrincipal.id -AppRoleValue 'Sites.Selected'

        Grants the Sites.Selected application permission when it is not already assigned.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]
        $ServicePrincipalId,

        [Parameter(Mandatory)]
        [string]
        $AppRoleValue
    )

    $graphResourceAppId = '00000003-0000-0000-c000-000000000000'
    $graphSpResult = Invoke-EntraRequest -Path 'servicePrincipals' -Query @{
        '$filter' = "appId eq '$graphResourceAppId'"
    }
    $graphSp = (Get-EntraCollectionValue -Response $graphSpResult) | Select-Object -First 1

    if (-not $graphSp -or -not $graphSp.id) {
        throw 'Der Service Principal von Microsoft Graph konnte nicht aufgeloest werden.'
    }

    $appRole = $graphSp.appRoles |
    Where-Object { $_.value -eq $AppRoleValue -and $_.allowedMemberTypes -contains 'Application' }

    if (-not $appRole) {
        throw "App Role '$AppRoleValue' wurde auf dem Microsoft-Graph-Service-Principal nicht gefunden."
    }

    # Bereits vorhandene Zuweisung prüfen, um keine Duplikate anzulegen.
    $assignmentsResult = Invoke-EntraRequest -Path "servicePrincipals/$ServicePrincipalId/appRoleAssignments"
    $existingAssignments = Get-EntraCollectionValue -Response $assignmentsResult
    $alreadyAssigned = $existingAssignments |
    Where-Object { $_.appRoleId -eq $appRole.id -and $_.resourceId -eq $graphSp.id }

    if ($alreadyAssigned) {
        Write-Verbose "App Role '$AppRoleValue' ist der Managed Identity bereits zugewiesen."
        return
    }

    $body = @{
        principalId = $ServicePrincipalId
        resourceId  = $graphSp.id
        appRoleId   = $appRole.id
    }

    Invoke-EntraJsonRequest -Method Post -Path "servicePrincipals/$ServicePrincipalId/appRoleAssignments" -Body $body | Out-Null
    Write-Verbose "App Role '$AppRoleValue' zugewiesen."
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
        $SiteUrl
    )

    $uri = [uri] $SiteUrl
    $hostname = $uri.Host
    $sitePath = $uri.AbsolutePath.Trim('/')
    $graphPath = if ($sitePath) { "sites/${hostname}:/${sitePath}" } else { "sites/${hostname}" }

    $site = Invoke-EntraRequest -Path $graphPath
    if (-not $site.id) {
        throw "Site '$SiteUrl' konnte nicht aufgeloest werden - Antwort enthielt keine 'id'. Pruefe die URL und die Berechtigung des angemeldeten Admins."
    }

    return $site.id
}

function Set-SharePointSitePermission {
    <#
    .SYNOPSIS
        Grants or updates an application's permission on a SharePoint site.

    .DESCRIPTION
        Checks whether the application already has a permission entry on the site. Updates the
        existing entry when found; otherwise, creates a new permission with the requested role.

    .PARAMETER SiteId
        The Microsoft Graph ID of the SharePoint site.

    .PARAMETER ApplicationId
        The application ID of the managed identity service principal.

    .PARAMETER ApplicationDisplayName
        The display name to include when creating a new application permission entry.

    .PARAMETER Role
        The SharePoint site role. Valid values are `read`, `write`, and `owner`.

    .OUTPUTS
        The Microsoft Graph permission object returned after creating or updating the permission.

    .EXAMPLE
        Set-SharePointSitePermission -SiteId $siteId -ApplicationId $servicePrincipal.appId `
            -ApplicationDisplayName $servicePrincipal.displayName -Role 'write'

        Grants the managed identity write access to the specified SharePoint site.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]
        $SiteId,

        [Parameter(Mandatory)]
        [string]
        $ApplicationId,
        [Parameter(Mandatory)]
        [string]
        $ApplicationDisplayName,

        [Parameter(Mandatory)]
        [ValidateSet('read', 'write', 'owner')]
        [string]
        $Role
    )

    # Vorhandene Permission-Einträge prüfen: Existiert schon einer für diese App, wird er
    # aktualisiert (PATCH) statt einen zweiten anzulegen.
    $permissionsResult = Invoke-EntraRequest -Path "sites/$SiteId/permissions"
    $existingPermissions = Get-EntraCollectionValue -Response $permissionsResult
    $existing = $existingPermissions | Where-Object {
        $_.grantedToIdentitiesV2.application.id -contains $ApplicationId -or
        $_.grantedToIdentities.application.id -contains $ApplicationId
    } | Select-Object -First 1

    if ($existing) {
        Write-Verbose "Bestehende Permission gefunden (Id: $($existing.id)) - aktualisiere Rolle auf '$Role'."
        $body = @{ roles = @($Role) }
        return Invoke-EntraJsonRequest -Method Patch -Path "sites/$SiteId/permissions/$($existing.id)" -Body $body
    }

    $body = @{
        roles               = @($Role)
        grantedToIdentities = @(
            @{
                application = @{
                    id          = $ApplicationId
                    displayName = $ApplicationDisplayName
                }
            }
        )
    }

    return Invoke-EntraJsonRequest -Method Post -Path "sites/$SiteId/permissions" -Body $body
}

# --- Ablauf ---

Write-Verbose 'Admin-Anmeldung (delegiert) über EntraAuth...'
Connect-AdminSession -TenantId $TenantId -ClientId $AdminClientId

Write-Verbose 'Löse Managed Identity auf...'
$servicePrincipal = if ($PSCmdlet.ParameterSetName -eq 'ByObjectId') {
    Get-ManagedIdentityServicePrincipal -ObjectId $ManagedIdentityObjectId
} else {
    Get-ManagedIdentityServicePrincipal -DisplayName $ManagedIdentityDisplayName
}

if (-not $servicePrincipal -or -not $servicePrincipal.id -or -not $servicePrincipal.appId) {
    throw 'Managed Identity konnte nicht (vollstaendig) aufgeloest werden. Abbruch, bevor mit leeren Werten weitergearbeitet wird.'
}

Write-Verbose "Managed Identity: $($servicePrincipal.displayName) (ObjectId: $($servicePrincipal.id), AppId: $($servicePrincipal.appId))"

Write-Verbose "Weise Graph-App-Role '$GraphAppRolePermission' zu (falls noch nicht vorhanden)..."
Grant-GraphAppRoleToServicePrincipal -ServicePrincipalId $servicePrincipal.id -AppRoleValue $GraphAppRolePermission

Write-Verbose "Löse Site-URL '$SiteUrl' auf..."
$siteId = Resolve-SharePointSiteId -SiteUrl $SiteUrl

Write-Verbose "Setze Site-Permission '$Role' für '$($servicePrincipal.displayName)' auf Site '$SiteId'..."
$permission = Set-SharePointSitePermission -SiteId $siteId `
    -ApplicationId $servicePrincipal.appId `
    -ApplicationDisplayName $servicePrincipal.displayName `
    -Role $Role

Write-Host "Fertig. Managed Identity '$($servicePrincipal.displayName)' hat jetzt '$Role'-Zugriff auf $SiteUrl."
Write-Host "Permission-Id: $($permission.id)"
