#Requires -Version 7.4
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Calls the Data API builder endpoint from PowerShell: REST, GraphQL, a stored procedure -
    with an Entra ID token, no API key.

.DESCRIPTION
    1. Gets a token for the API with Get-AzAccessToken and shows its claims (aud, iss, roles).
    2. Checks the anonymous root endpoint and that anonymous data access is denied.
    3. Reads the health report, events (paged), a filtered list, one event by key, sessions
       (field-level security: no SpeakerEmail for readers) and the stored procedure.
    4. Runs a GraphQL query with a relationship (events -> sessions).
    5. With -IncludeWrite: creates, changes and deletes a session as 'writer'.
       Needs the app role 'writer' (scripts/Grant-DabApiRole.ps1).

.PARAMETER ApiUrl
    Base URI of the Data API Builder endpoint, for example https://api.example.com.

.PARAMETER ApiClientId
    Client/application ID of the API registration. It is used to request a token
    for the api://<ApiClientId> audience.

.PARAMETER TenantId
    Optional Microsoft Entra tenant ID passed to Get-AzAccessToken. If omitted,
    the current Az.Accounts context is used.

.PARAMETER IncludeWrite
    Also test creating, updating, and deleting a session. Requires a token with
    the 'writer' app role. The session created by the script is deleted afterward.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id>
    $test = @{
        ApiUrl      = (terraform -chdir=infra output -raw api_url)
        ApiClientId = (terraform -chdir=infra output -raw api_client_id)
    }
    ./scripts/Test-DabApi.ps1 @test -IncludeWrite

.EXAMPLE
    ./scripts/Test-DabApi.ps1 -ApiUrl 'https://api.example.com' `
        -ApiClientId '00000000-0000-0000-0000-000000000000' `
        -TenantId '11111111-1111-1111-1111-111111111111'
    Runs the API checks using the specified endpoint, application ID, and tenant.

.NOTES
    Requires PowerShell 7.4 and the Az.Accounts module. Sign in with
    Connect-AzAccount before running. The API must expose the endpoints and roles
    exercised by this demo. Use Get-Help ./scripts/Test-DabApi.ps1 -Full for details.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive demo output.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'ApiUrl is used in the helper functions.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [uri]
    $ApiUrl,

    [Parameter(Mandatory)]
    [guid]
    $ApiClientId,

    [Parameter()]
    [string]
    $TenantId,

    [Parameter()]
    [switch]
    $IncludeWrite
)

$ErrorActionPreference = 'Stop'

#region Helpers
function Write-Step {
    <#
        .SYNOPSIS
        Writes a section heading to the console.

        .DESCRIPTION
        Writes an empty line and the text, prefixed with "==", in cyan. Separates the
        steps of the demo in the console output.

        .PARAMETER Text
        The heading to write.

        .EXAMPLE
        Write-Step 'Token'
    #>

    param(
        [Parameter()]
        [string]
        $Text
    )
    Write-Host "`n== $Text" -ForegroundColor Cyan
}

function ConvertFrom-Jwt {
    <#
        .SYNOPSIS
        Decodes the payload of a JSON Web Token.

        .DESCRIPTION
        Takes the second segment of the token, converts it from Base64url to Base64,
        adds the missing padding and returns the claims as an object. The signature
        is not validated - that's DAB's job.

        .PARAMETER Token
        The access token as SecureString, as Get-AzAccessToken returns it.

        .OUTPUTS
        System.Management.Automation.PSCustomObject
        Returns the claims of the token (aud, iss, scp, roles, ...).

        .EXAMPLE
        ConvertFrom-Jwt -Token (Get-AzAccessToken -ResourceUrl "api://$ApiClientId").Token
    #>

    [OutputType([System.Management.Automation.PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [securestring]
        $Token
    )
    $payload = (ConvertFrom-SecureString -SecureString $Token -AsPlainText).Split('.')[1].Replace('-', '+').Replace('_', '/')
    $payload = $payload.PadRight($payload.Length + (4 - $payload.Length % 4) % 4, '=')
    [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
}

function Invoke-Dab {
    <#
        .SYNOPSIS
        Sends a request to the Data API builder endpoint.

        .DESCRIPTION
        Combines ApiUrl and the path, sends the access token from the Token step as
        bearer token and, when supplied, the role in the X-MS-API-ROLE header and the
        body as JSON.

        Without ExpectStatus, a failed request throws. Up to four retries cover the
        cold start of a container app that scaled to zero.
        With ExpectStatus, HTTP errors do not throw. The function compares the status
        code with the expected values, throws on a mismatch and returns the status code.

        .PARAMETER Path
        Path relative to ApiUrl, including the query string, for example '/api/Event'.

        .PARAMETER Method
        HTTP method to use. Valid values are GET, POST, PUT, PATCH, and DELETE.

        .PARAMETER Body
        Optional request body, serialized to JSON before sending.

        .PARAMETER Role
        Role DAB evaluates the request with (X-MS-API-ROLE header). Must be an app role
        in the token. Without it, DAB uses the role authenticated.

        .PARAMETER Anonymous
        Sends the request without a token.

        .PARAMETER ExpectStatus
        One or more expected HTTP status codes. Returns the status code instead of the
        response body.

        .OUTPUTS
        System.Object
        Returns the response from Invoke-RestMethod, or the status code with ExpectStatus.

        .EXAMPLE
        (Invoke-Dab -Path '/api/Event').value

        .EXAMPLE
        Invoke-Dab -Path '/api/Event' -Anonymous -ExpectStatus 401, 403

        .EXAMPLE
        Invoke-Dab -Path '/api/Session' -Method POST -Role writer -Body $newSession
    #>

    [OutputType([System.Object])]
    param(
        [Parameter(Mandatory)]
        [string]
        $Path,

        [Parameter()]
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string]
        $Method = 'GET',

        [Parameter()]
        [object]
        $Body,

        [Parameter()]
        [string]
        $Role,

        [Parameter()]
        [switch]
        $Anonymous,

        [Parameter()]
        [int[]]
        $ExpectStatus
    )
    $request = @{
        Uri         = [uri]::new($ApiUrl, $Path)
        Method      = $Method
        ContentType = 'application/json'
        Headers     = @{}
    }
    if (-not $Anonymous) {
        $request.Authentication = 'Bearer'
        $request.Token = $script:token
        if ($ApiUrl.Scheme -eq 'http') { $request.AllowUnencryptedAuthentication = $true }   # local container
    }
    if ($Role) { $request.Headers['X-MS-API-ROLE'] = $Role }
    if ($PSBoundParameters.ContainsKey('Body')) { $request.Body = $Body | ConvertTo-Json -Depth 10 -Compress }

    if ($ExpectStatus) {
        $null = Invoke-RestMethod @request -SkipHttpErrorCheck -StatusCodeVariable status
        if ($status -notin $ExpectStatus) { throw "$Method $Path returned $status, expected $($ExpectStatus -join ' or ')." }
        return $status
    }

    # The container scales to zero: the first call after a quiet period waits for a cold start.
    Invoke-RestMethod @request -MaximumRetryCount 4 -RetryIntervalSec 10
}

function Get-DabPage {
    <#
        .SYNOPSIS
        Reads all rows of a paged REST request.

        .DESCRIPTION
        Calls Invoke-Dab and follows nextLink until all rows are read. Writes the rows
        of every page to the pipeline. DAB returns relative links (next-link-relative),
        so every page goes to the same ApiUrl.

        .PARAMETER Path
        Path of the first page relative to ApiUrl, including the query string.

        .OUTPUTS
        System.Management.Automation.PSCustomObject
        Returns one object per row.

        .EXAMPLE
        Get-DabPage -Path '/api/Event?$orderby=EventDate&$first=2'
    #>

    [OutputType([System.Management.Automation.PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]
        $Path
    )

    while ($Path) {
        $page = Invoke-Dab -Path $Path
        $page.value
        $Path = $page.nextLink
    }
}

function Invoke-DabGraphQL {
    <#
        .SYNOPSIS
        Sends a GraphQL query or mutation to the Data API builder endpoint.

        .DESCRIPTION
        Posts the query and its variables to /graphql with Invoke-Dab. GraphQL answers
        errors with HTTP 200, so the function throws when the response contains errors
        and returns the data otherwise.

        .PARAMETER Query
        The GraphQL query or mutation.

        .PARAMETER Variables
        Values for the variables the query declares.

        .PARAMETER Role
        Role DAB evaluates the request with (X-MS-API-ROLE header).

        .OUTPUTS
        System.Management.Automation.PSCustomObject
        Returns the data property of the response.

        .EXAMPLE
        Invoke-DabGraphQL -Query 'query { executeUpcomingEvents(Days: 30) { Title } }'

        .EXAMPLE
        Invoke-DabGraphQL -Role writer -Query $mutation -Variables @{ id = 1; item = @{ Title = 'New title' } }
    #>

    [OutputType([System.Management.Automation.PSCustomObject])]
    param(
        [Parameter(Mandatory)][string] $Query,
        [hashtable] $Variables = @{},
        [string] $Role
    )
    $result = Invoke-Dab -Path '/graphql' -Method POST -Role $Role -Body @{ query = $Query; variables = $Variables }
    if ($result.errors) { throw ($result.errors.message -join '; ') }
    $result.data
}
#endregion

#region 1. Token
Write-Step 'Token'
$tokenRequest = @{ ResourceUrl = "api://$ApiClientId" }
if ($TenantId) { $tokenRequest.TenantId = $TenantId }
$script:token = (Get-AzAccessToken @tokenRequest).Token   # SecureString (Az.Accounts 5+)

$claims = ConvertFrom-Jwt -Token $script:token
[pscustomobject]@{
    aud   = $claims.aud
    iss   = $claims.iss
    ver   = $claims.ver
    scp   = $claims.scp
    roles = $claims.roles -join ', '
    upn   = $claims.upn ?? $claims.azp
} | Format-List | Out-Host
if ($claims.ver -ne '2.0') { Write-Warning 'v1 token: DAB expects iss .../v2.0. Set requestedAccessTokenVersion = 2 on the API.' }
#endregion

#region 2. Anonymous
Write-Step 'Anonymous root endpoint (no token)'
Invoke-Dab -Path '/' -Anonymous | Format-List | Out-Host

Write-Step 'Anonymous data access must be denied'
$status = Invoke-Dab -Path '/api/Event' -Anonymous -ExpectStatus 401, 403
"GET /api/Event without token -> $status"
#endregion

#region 3. REST reads
Write-Step 'Health report (role: authenticated)'
$health = Invoke-Dab -Path '/health'
"Status: $($health.status), role: $($health.currentRole), DAB $($health.version)"
$health.checks | Select-Object name, status, @{ n = 'tags'; e = { $_.tags -join ',' } }, @{ n = 'ms'; e = { $_.data.'response-ms' } } |
    Format-Table | Out-Host

Write-Step 'All events, 2 per page, ordered by date'
Get-DabPage -Path '/api/Event?$select=EventId,Title,EventDate,IsOnline&$orderby=EventDate&$first=2' |
    Format-Table EventId, Title, EventDate, IsOnline | Out-Host

Write-Step 'Filter: online events only'
$filter = [uri]::EscapeDataString('IsOnline eq true')
(Invoke-Dab -Path "/api/Event?`$filter=$filter").value | Format-Table EventId, Title, Location | Out-Host

Write-Step 'Stored procedure: upcoming events in the next 60 days'
$upcoming = (Invoke-Dab -Path '/api/UpcomingEvents?Days=60').value
$upcoming | Format-Table EventId, Title, EventDate, SessionCount | Out-Host

$eventId = ($upcoming | Select-Object -First 1).EventId
if (-not $eventId) { throw 'No upcoming event found - did the seed script run?' }

Write-Step "One event by primary key: /api/Event/EventId/$eventId"
(Invoke-Dab -Path "/api/Event/EventId/$eventId").value | Format-List | Out-Host

Write-Step 'Sessions as reader: SpeakerEmail is excluded for the role authenticated'
$filter = [uri]::EscapeDataString("EventId eq $eventId")
$sessions = (Invoke-Dab -Path "/api/Session?`$filter=$filter").value
$sessions | Format-Table SessionId, Title, Speaker, Level | Out-Host
"SpeakerEmail returned: $([bool]($sessions[0].PSObject.Properties.Name -contains 'SpeakerEmail'))"
#endregion

#region 4. GraphQL
Write-Step 'GraphQL: events with their sessions (relationship)'
$query = @'
query ($first: Int) {
  events(first: $first, orderBy: { EventDate: ASC }, filter: { IsOnline: { eq: false } }) {
    items {
      EventId
      Title
      EventDate
      sessions {
        items { Title Speaker Level DurationMinutes }
      }
    }
  }
}
'@
$data = Invoke-DabGraphQL -Query $query -Variables @{ first = 10 }
foreach ($meetup in $data.events.items) {
    '{0:yyyy-MM-dd}  {1}' -f [datetime]$meetup.EventDate, $meetup.Title
    foreach ($session in $meetup.sessions.items) {
        '            {0} ({1}, L{2}, {3} min)' -f $session.Title, $session.Speaker, $session.Level, $session.DurationMinutes
    }
}

Write-Step 'GraphQL: the stored procedure'
(Invoke-DabGraphQL -Query 'query { executeUpcomingEvents(Days: 30) { Title SessionCount } }').executeUpcomingEvents |
    Format-Table | Out-Host
#endregion

#region 5. Writes
if (-not $IncludeWrite) { return }

Write-Step 'Write without the role header must be denied (role: authenticated)'
$newSession = @{
    EventId         = $eventId
    Title           = 'Demo session from Test-DabApi.ps1'
    Speaker         = 'Test Script'
    SpeakerEmail    = 'test@example.com'
    Level           = 100
    DurationMinutes = 15
}
$status = Invoke-Dab -Path '/api/Session' -Method POST -Body $newSession -ExpectStatus 403
"POST /api/Session without X-MS-API-ROLE -> $status"

if ($claims.roles -notcontains 'writer') {
    Write-Warning "The token has no 'writer' role. Assign it with Grant-DabApiRole.ps1, then sign in again (Connect-AzAccount) for a fresh token."
    return
}

Write-Step 'Create a session (X-MS-API-ROLE: writer)'
$created = (Invoke-Dab -Path '/api/Session' -Method POST -Role writer -Body $newSession).value[0]
$created | Format-List | Out-Host

try {
    Write-Step "Change it: PATCH /api/Session/SessionId/$($created.SessionId)"
    (Invoke-Dab -Path "/api/Session/SessionId/$($created.SessionId)" -Method PATCH -Role writer -Body @{ DurationMinutes = 20 }).value |
        Format-Table SessionId, Title, DurationMinutes, SpeakerEmail | Out-Host

    Write-Step 'GraphQL mutation: change the title'
    $mutation = @'
mutation ($id: Int!, $item: UpdateSessionInput!) {
  updateSession(SessionId: $id, item: $item) { SessionId Title }
}
'@
    (Invoke-DabGraphQL -Role writer -Query $mutation -Variables @{
        id   = $created.SessionId
        item = @{ Title = 'Demo session (renamed via GraphQL)' }
    }).updateSession | Format-Table | Out-Host
}
finally {
    Write-Step "Delete it: DELETE /api/Session/SessionId/$($created.SessionId)"
    $status = Invoke-Dab -Path "/api/Session/SessionId/$($created.SessionId)" -Method DELETE -Role writer -ExpectStatus 204
    "DELETE -> $status"
}
#endregion
