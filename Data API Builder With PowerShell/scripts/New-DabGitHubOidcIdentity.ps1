#Requires -Version 7.4
#Requires -Modules Az.Accounts, Az.Resources, Az.Storage
<#
.SYNOPSIS
    One-time bootstrap for the Data API builder sample: GitHub Actions identity (OIDC),
    Terraform state, SQL admin group and - optionally - the GitHub repository variables.

.DESCRIPTION
    Creates or reuses:
      1. An app registration + service principal for GitHub Actions with federated credentials
         for the main branch, pull requests and the environment 'production'. No client secret.
      2. Microsoft Graph application permission Application.ReadWrite.OwnedBy (admin consent),
         so Terraform can create the API app registration - and only manage apps it owns.
      3. Azure role assignments on the subscription: Contributor and Role Based Access Control
         Administrator, the latter with a condition that only allows AcrPull and AcrPush.
      4. A storage account for the Terraform state (Entra ID only, shared keys disabled).
      5. A security group that becomes the SQL server's Microsoft Entra admin. Members: the
         pipeline identity and you.
      6. With -ResolveGitHubId: use immutable GitHub owner and repository IDs in OIDC subjects
         (needs gh).
      7. With -ConfigureGitHub: repository variables and the environment 'production' (needs gh).

    Run it as a user who can create app registrations, grant admin consent for Graph
    application permissions (Privileged Role Administrator or Global Administrator) and
    assign roles on the subscription (Owner or User Access Administrator).
    Microsoft Graph is called with REST and a token from Az.Accounts - no Graph SDK needed.

.PARAMETER ResolveGitHubId
    Use immutable owner and repository IDs in the OIDC subject claim. Requires the GitHub CLI
    and is needed when the repository uses immutable subject claims.

.EXAMPLE
    Connect-AzAccount -Tenant <tenant-id> -Subscription <subscription-id>
    $bootstrap = @{
        GitHubOrganization = 'constantinhager'
        GitHubRepository   = 'BlogAssets'
        ResolveGitHubId    = $true
        ConfigureGitHub    = $true
    }
    ./scripts/New-DabGitHubOidcIdentity.ps1 @bootstrap
#>
[CmdletBinding(SupportsShouldProcess)]
[OutputType([System.Management.Automation.PSCustomObject])]
param(
    [Parameter(Mandatory)]
    [string]
    $GitHubOrganization,

    [Parameter(Mandatory)]
    [string]
    $GitHubRepository,

    [Parameter()]
    [string]
    $SubscriptionId = (Get-AzContext).Subscription.Id,

    [Parameter()]
    [string]
    $Location = 'germanywestcentral',

    [Parameter()]
    [string]
    $AppDisplayName = 'github-dab-sql-deploy',

    [Parameter()]
    [string]
    $EnvironmentName = 'production',

    [Parameter()]
    [string]
    $SqlAdminGroupName = 'sg-dab-sql-admins',

    [Parameter()]
    [string]
    $StateResourceGroupName = 'rg-dab-tfstate',

    [Parameter()]
    [ValidatePattern('^[a-z0-9]{3,24}$')]
    [string]
    $StateStorageAccountName,

    [Parameter()]
    [string]
    $StateContainerName = 'tfstate',

    [Parameter()]
    [switch]
    $ResolveGitHubId,

    [Parameter()]
    [switch]
    $ConfigureGitHub
)

$ErrorActionPreference = 'Stop'

$graphAppId = '00000003-0000-0000-c000-000000000000'
$appReadWriteOwnedBy = '18a4783c-866b-4cc7-a460-3d5e5662c884'   # Application.ReadWrite.OwnedBy
$acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
$acrPushRoleId = '8311e382-0749-4cb8-b61a-304f252e45ec'

function Invoke-Graph {
    <#
        .SYNOPSIS
        Sends an authenticated request to Microsoft Graph.

        .DESCRIPTION
        Gets a Microsoft Graph access token from the current Azure context and
        invokes the requested Microsoft Graph v1.0 endpoint. When supplied, the
        request body is serialized as JSON.

        .PARAMETER Method
        HTTP method to use. Valid values are GET, POST, PATCH, and DELETE.

        .PARAMETER Path
        Microsoft Graph API path, with or without a leading slash.

        .PARAMETER Body
        Optional request body, serialized to JSON before sending.

        .OUTPUTS
        System.Object
        Returns the response from Invoke-RestMethod.

        .EXAMPLE
        Invoke-Graph -Path 'applications'

        .EXAMPLE
        Invoke-Graph -Method POST -Path 'applications' -Body $application
    #>

    [CmdletBinding()]
    [OutputType([System.Object])]
    param(
        [ValidateSet('GET', 'POST', 'PATCH', 'DELETE')]
        [string]
        $Method = 'GET',

        [Parameter(Mandatory)]
        [string]
        $Path,

        [Parameter()]
        [object]
        $Body
    )
    # Az.Accounts 5+ always returns the token as SecureString.
    $token = (Get-AzAccessToken -ResourceTypeName MSGraph).Token
    $request = @{
        Method         = $Method
        Uri            = "https://graph.microsoft.com/v1.0/$($Path.TrimStart('/'))"
        Authentication = 'Bearer'
        Token          = $token
        ContentType    = 'application/json'
    }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $request.Body = $Body | ConvertTo-Json -Depth 10 -Compress
    }
    Invoke-RestMethod @request
}

function Wait-GraphObject {
    <#
        .SYNOPSIS
        Waits for a Microsoft Graph object to become available.

        .DESCRIPTION
        Retries a Microsoft Graph request while a newly created directory object
        propagates across Graph replicas. Checks up to 12 times, pausing 5 seconds
        between attempts. Returns the object when the request succeeds and throws
        an error if it remains unavailable.

        .PARAMETER Path
        The Microsoft Graph API path of the object to retrieve.

        .OUTPUTS
        System.Object
        Returns the object returned by Microsoft Graph.

        .EXAMPLE
        Wait-GraphObject -Path "servicePrincipals/$servicePrincipalId"
    #>

    # New directory objects take a few seconds until every Graph and ARM replica knows them.
    [CmdletBinding()]
    [OutputType([System.Management.Automation.PSCustomObject])]
    param(
        [Parameter(Mandatory)]
        [string]
        $Path
    )

    foreach ($attempt in 1..12) {
        try { return Invoke-Graph -Path $Path }
        catch { Start-Sleep -Seconds 5 }
    }
    throw "Object '$Path' did not show up in Microsoft Graph."
}

$context = Get-AzContext
if (-not $context) { throw 'Run Connect-AzAccount first.' }
$tenantId = $context.Tenant.Id
$null = Set-AzContext -Subscription $SubscriptionId
$subscriptionScope = "/subscriptions/$SubscriptionId"
$me = Invoke-Graph -Path 'me?$select=id,userPrincipalName'
Write-Verbose "Signed in as $($me.userPrincipalName)"

#region 1. App registration, service principal, federated credentials
$app = (Invoke-Graph -Path "applications?`$filter=displayName eq '$AppDisplayName'").value | Select-Object -First 1
if (-not $app -and $PSCmdlet.ShouldProcess($AppDisplayName, 'Create app registration')) {
    $app = Invoke-Graph -Method POST -Path 'applications' -Body @{
        displayName    = $AppDisplayName
        signInAudience = 'AzureADMyOrg'
        notes          = "GitHub Actions deployment identity for $GitHubOrganization/$GitHubRepository (Data API builder sample). No secrets - federated credentials only."
    }
}

$sp = (Invoke-Graph -Path "servicePrincipals?`$filter=appId eq '$($app.appId)'").value | Select-Object -First 1
if (-not $sp -and $PSCmdlet.ShouldProcess($AppDisplayName, 'Create service principal')) {
    $sp = Invoke-Graph -Method POST -Path 'servicePrincipals' -Body @{ appId = $app.appId }
    $null = Wait-GraphObject -Path "servicePrincipals/$($sp.id)"
}

$repoClaim = '{0}/{1}' -f $GitHubOrganization, $GitHubRepository
if ($ResolveGitHubId) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw 'The GitHub CLI (gh) is required for -ResolveGitHubId.'
    }

    $repo = "$GitHubOrganization/$GitHubRepository"
    $repoInfoJson = gh api "repos/$repo"
    if ($LASTEXITCODE -ne 0) {
        throw "The GitHub CLI failed to resolve immutable IDs for '$repo'."
    }

    $repoInfo = $repoInfoJson | ConvertFrom-Json -ErrorAction Stop
    if (-not $repoInfo.owner.id -or -not $repoInfo.id) {
        throw "The GitHub API response did not contain owner and repository IDs for '$repo'."
    }

    $repoClaim = '{0}@{1}/{2}@{3}' -f $GitHubOrganization, $repoInfo.owner.id,
        $GitHubRepository, $repoInfo.id
}

$subjects = [ordered]@{
    'github-main'         = "repo:${repoClaim}:ref:refs/heads/main"
    'github-pull-request' = "repo:${repoClaim}:pull_request"
    "github-env-$EnvironmentName" = "repo:${repoClaim}:environment:$EnvironmentName"
}
$existingCredentials = (Invoke-Graph -Path "applications/$($app.id)/federatedIdentityCredentials").value
foreach ($name in $subjects.Keys) {
    $existingCredential = $existingCredentials |
        Where-Object name -eq $name |
        Select-Object -First 1
    if ($existingCredential -and $existingCredential.subject -eq $subjects[$name]) { continue }

    if ($PSCmdlet.ShouldProcess($subjects[$name], 'Set federated credential')) {
        if ($existingCredential) {
            $credentialRequest = @{
                Method = 'PATCH'
                Path   = "applications/$($app.id)/federatedIdentityCredentials/$($existingCredential.id)"
                Body   = @{ subject = $subjects[$name] }
            }
            $null = Invoke-Graph @credentialRequest
            continue
        }

        $null = Invoke-Graph -Method POST -Path "applications/$($app.id)/federatedIdentityCredentials" -Body @{
            name      = $name
            issuer    = 'https://token.actions.githubusercontent.com'
            subject   = $subjects[$name]
            audiences = @('api://AzureADTokenExchange')
        }
    }
}
#endregion

#region 2. Graph: Application.ReadWrite.OwnedBy (admin consent = app role assignment)
$graphSp = Invoke-Graph -Path "servicePrincipals(appId='$graphAppId')?`$select=id"
$grants = (Invoke-Graph -Path "servicePrincipals/$($sp.id)/appRoleAssignments").value
if ($grants.appRoleId -notcontains $appReadWriteOwnedBy -and
    $PSCmdlet.ShouldProcess($AppDisplayName, 'Grant Graph Application.ReadWrite.OwnedBy')) {
    $null = Invoke-Graph -Method POST -Path "servicePrincipals/$($sp.id)/appRoleAssignments" -Body @{
        principalId = $sp.id
        resourceId  = $graphSp.id
        appRoleId   = $appReadWriteOwnedBy
    }
}
#endregion

#region 3. Azure role assignments
function Set-RoleAssignment {
    <#
        .SYNOPSIS
        Assigns an Azure role to a principal if the assignment does not already exist.

        .DESCRIPTION
        Checks for an existing role assignment matching the principal, role, and
        scope. If none exists, uses ShouldProcess to create the assignment. An
        optional condition is applied to limit the actions permitted by the role.

        .PARAMETER ObjectId
        The object ID of the principal receiving the role assignment.

        .PARAMETER RoleName
        The name of the Azure role definition to assign.

        .PARAMETER Scope
        The Azure resource ID defining the scope of the role assignment.

        .PARAMETER Condition
        Optional Azure role-assignment condition that restricts the assignment.

        .OUTPUTS
        System.Management.Automation.PSCustomObject
        Returns no object when the assignment already exists or is declined;
        otherwise creates the role assignment.

        .EXAMPLE
        Set-RoleAssignment -ObjectId $principalId -RoleName 'Contributor' `
            -Scope '/subscriptions/<subscription-id>'

        .EXAMPLE
        Set-RoleAssignment -ObjectId $principalId -RoleName 'Storage Blob Data Contributor' `
            -Scope $storageAccount.Id -WhatIf
    #>
    [OutputType([System.Management.Automation.PSCustomObject])]
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $ObjectId,
        [Parameter(Mandatory)][string] $RoleName,
        [Parameter(Mandatory)][string] $Scope,
        [string] $Condition
    )
    $existing = Get-AzRoleAssignment -ObjectId $ObjectId -RoleDefinitionName $RoleName -Scope $Scope -ErrorAction SilentlyContinue |
        Where-Object Scope -EQ $Scope
    if ($existing) { return }
    if (-not $PSCmdlet.ShouldProcess("$RoleName on $Scope", 'Assign role')) { return }

    $assignment = @{
        ObjectId           = $ObjectId
        ObjectType         = 'ServicePrincipal'   # skips the directory lookup of a brand-new principal
        RoleDefinitionName = $RoleName
        Scope              = $Scope
    }
    if ($Condition) {
        $assignment.Condition = $Condition
        $assignment.ConditionVersion = '2.0'
    }
    $null = New-AzRoleAssignment @assignment
}

Set-RoleAssignment -ObjectId $sp.id -RoleName 'Contributor' -Scope $subscriptionScope

# The pipeline may only assign (and remove) AcrPull and AcrPush - nothing else.
$roleList = "$acrPullRoleId, $acrPushRoleId"
$condition = @"
((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'}))
  OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roleList}))
AND
((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'}))
  OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$roleList}))
"@
Set-RoleAssignment -ObjectId $sp.id -RoleName 'Role Based Access Control Administrator' -Scope $subscriptionScope -Condition $condition
#endregion

#region 4. Terraform state (Entra ID only)
if (-not (Get-AzResourceGroup -Name $StateResourceGroupName -ErrorAction SilentlyContinue) -and
    $PSCmdlet.ShouldProcess($StateResourceGroupName, 'Create resource group')) {
    $null = New-AzResourceGroup -Name $StateResourceGroupName -Location $Location
}

$stateAccount = if ($StateStorageAccountName) {
    Get-AzStorageAccount -ResourceGroupName $StateResourceGroupName -Name $StateStorageAccountName -ErrorAction SilentlyContinue
}
else {
    Get-AzStorageAccount -ResourceGroupName $StateResourceGroupName -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $stateAccount) {
    if (-not $StateStorageAccountName) { $StateStorageAccountName = 'sttfdab{0:d5}' -f (Get-Random -Maximum 99999) }
    if ($PSCmdlet.ShouldProcess($StateStorageAccountName, 'Create storage account')) {
        $stateAccount = New-AzStorageAccount -ResourceGroupName $StateResourceGroupName -Name $StateStorageAccountName `
            -Location $Location -SkuName Standard_LRS -Kind StorageV2 -MinimumTlsVersion TLS1_2 `
            -AllowBlobPublicAccess $false -AllowSharedKeyAccess $false
    }
}
if ($stateAccount -and -not (Get-AzRmStorageContainer -StorageAccount $stateAccount -Name $StateContainerName -ErrorAction SilentlyContinue) -and
    $PSCmdlet.ShouldProcess($StateContainerName, 'Create blob container')) {
    $null = New-AzRmStorageContainer -StorageAccount $stateAccount -Name $StateContainerName
}
if ($stateAccount) {
    Set-RoleAssignment -ObjectId $sp.id -RoleName 'Storage Blob Data Contributor' -Scope $stateAccount.Id
}
#endregion

#region 5. SQL admin group
$group = (Invoke-Graph -Path "groups?`$filter=displayName eq '$SqlAdminGroupName'&`$select=id,displayName").value | Select-Object -First 1
if (-not $group -and $PSCmdlet.ShouldProcess($SqlAdminGroupName, 'Create security group')) {
    $group = Invoke-Graph -Method POST -Path 'groups' -Body @{
        displayName           = $SqlAdminGroupName
        description           = 'Microsoft Entra admins of the Data API builder sample SQL server.'
        mailEnabled           = $false
        mailNickname          = ($SqlAdminGroupName -replace '[^a-zA-Z0-9]', '')
        securityEnabled       = $true
        'owners@odata.bind'   = @("https://graph.microsoft.com/v1.0/users/$($me.id)")
        'members@odata.bind'  = @(
            "https://graph.microsoft.com/v1.0/directoryObjects/$($me.id)"
            "https://graph.microsoft.com/v1.0/directoryObjects/$($sp.id)"
        )
    }
}
elseif ($group) {
    $members = (Invoke-Graph -Path "groups/$($group.id)/members?`$select=id").value.id
    foreach ($memberId in @($me.id, $sp.id)) {
        if ($members -contains $memberId) { continue }
        if ($PSCmdlet.ShouldProcess($SqlAdminGroupName, "Add member $memberId")) {
            $null = Invoke-Graph -Method POST -Path "groups/$($group.id)/members/`$ref" -Body @{
                '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$memberId"
            }
        }
    }
}
#endregion

$result = [pscustomobject]@{
    AZURE_CLIENT_ID         = $app.appId
    AZURE_TENANT_ID         = $tenantId
    AZURE_SUBSCRIPTION_ID   = $SubscriptionId
    TFSTATE_RESOURCE_GROUP  = $StateResourceGroupName
    TFSTATE_STORAGE_ACCOUNT = $stateAccount.StorageAccountName
    SQL_ADMIN_GROUP_NAME    = $group.displayName
    SQL_ADMIN_GROUP_ID      = $group.id
}

#region 6. GitHub repository variables and environment
if ($ConfigureGitHub) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'The GitHub CLI (gh) is required for -ConfigureGitHub.' }
    $repo = "$GitHubOrganization/$GitHubRepository"
    if ($PSCmdlet.ShouldProcess($repo, 'Set repository variables and environment')) {
        foreach ($property in $result.PSObject.Properties) {
            gh variable set $property.Name --repo $repo --body "$($property.Value)"
            if ($LASTEXITCODE) { throw "gh variable set $($property.Name) failed." }
        }
        gh api --method PUT "repos/$repo/environments/$EnvironmentName" --silent
        if ($LASTEXITCODE) { throw "Creating the environment '$EnvironmentName' failed." }
    }
}
#endregion

$result
