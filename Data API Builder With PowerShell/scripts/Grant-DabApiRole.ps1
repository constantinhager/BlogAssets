#Requires -Version 7.4
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Assigns an app role of the meetup data API ('reader' or 'writer') to a user, a group or a
    service principal / managed identity.

.DESCRIPTION
    The API's service principal requires an app role assignment before Entra ID issues a token
    for it. This script creates that assignment with Microsoft Graph (REST, token from Az.Accounts).

    Run it as a Cloud Application Administrator, Application Administrator or Privileged Role
    Administrator. The pipeline can't do it on purpose: AppRoleAssignment.ReadWrite.All would let
    it grant any app role in the tenant - including Microsoft Graph permissions to itself.

    Assigning a group needs Microsoft Entra ID P1 or higher. Nested groups don't count.

.EXAMPLE
    $api = terraform -chdir=infra output -raw api_client_id
    ./scripts/Grant-DabApiRole.ps1 -ApiClientId $api -Role writer -UserPrincipalName 'admin@contoso.com'

.EXAMPLE
    # A managed identity that calls the API (app-only token):
    ./scripts/Grant-DabApiRole.ps1 -ApiClientId $api -Role reader -ServicePrincipalObjectId $principalId
#>
[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'User')]
param(
    [Parameter(Mandatory)]
    [guid] $ApiClientId,

    [Parameter(Mandatory)]
    [ValidateSet('reader', 'writer')]
    [string] $Role,

    [Parameter(Mandatory, ParameterSetName = 'User')]
    [string] $UserPrincipalName,

    [Parameter(Mandatory, ParameterSetName = 'Group')]
    [guid] $GroupObjectId,

    [Parameter(Mandatory, ParameterSetName = 'ServicePrincipal')]
    [guid] $ServicePrincipalObjectId
)

$ErrorActionPreference = 'Stop'

function Invoke-Graph {
    [CmdletBinding()]
    param(
        [string] $Method = 'GET',
        [Parameter(Mandatory)][string] $Path,
        [object] $Body
    )
    $request = @{
        Method         = $Method
        Uri            = "https://graph.microsoft.com/v1.0/$Path"
        Authentication = 'Bearer'
        Token          = (Get-AzAccessToken -ResourceTypeName MSGraph).Token
        ContentType    = 'application/json'
    }
    if ($PSBoundParameters.ContainsKey('Body')) { $request.Body = $Body | ConvertTo-Json -Depth 5 -Compress }
    Invoke-RestMethod @request
}

$apiSp = (Invoke-Graph -Path "servicePrincipals?`$filter=appId eq '$ApiClientId'&`$select=id,displayName,appRoles").value |
    Select-Object -First 1
if (-not $apiSp) { throw "No service principal for app $ApiClientId in this tenant." }

$appRole = $apiSp.appRoles | Where-Object { $_.value -eq $Role -and $_.isEnabled }
if (-not $appRole) { throw "The API has no enabled app role '$Role'." }

$principalId = switch ($PSCmdlet.ParameterSetName) {
    'User'             { (Invoke-Graph -Path "users/$([uri]::EscapeDataString($UserPrincipalName))?`$select=id").id }
    'Group'            { $GroupObjectId.ToString() }
    'ServicePrincipal' { $ServicePrincipalObjectId.ToString() }
}

# Already assigned? appRoleAssignedTo is small for one API, so filter on the client.
$path = "servicePrincipals/$($apiSp.id)/appRoleAssignedTo"
$assignments = [System.Collections.Generic.List[object]]::new()
while ($path) {
    $page = Invoke-Graph -Path $path
    $assignments.AddRange(@($page.value))
    $path = $page.'@odata.nextLink' -replace '^https://graph.microsoft.com/v1.0/', ''
}
$existing = $assignments | Where-Object { $_.principalId -eq $principalId -and $_.appRoleId -eq $appRole.id }
if ($existing) {
    Write-Verbose "$($existing.principalDisplayName) already has '$Role' on $($apiSp.displayName)."
    return $existing
}

if ($PSCmdlet.ShouldProcess("$principalId", "Assign app role '$Role' of $($apiSp.displayName)")) {
    Invoke-Graph -Method POST -Path "servicePrincipals/$($apiSp.id)/appRoleAssignedTo" -Body @{
        principalId = $principalId
        resourceId  = $apiSp.id
        appRoleId   = $appRole.id
    }
}
