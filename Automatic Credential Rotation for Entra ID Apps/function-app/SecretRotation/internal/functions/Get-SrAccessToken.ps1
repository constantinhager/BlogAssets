function Get-SrAccessToken {
	<#
	.SYNOPSIS
		Returns an access token for a resource.

	.DESCRIPTION
		Returns an access token for a resource. There are two paths, and the resource decides which one:

		Microsoft Graph (any tenant, home tenant included):
		  The token belongs to the multi-tenant rotation app SR_ROTATION_APP_ID. The function gets a token
		  of its user-assigned managed identity for 'api://AzureADTokenExchange' and exchanges it in the
		  target tenant (managed identity as federated identity credential). The managed identity itself
		  has no Graph permission at all.

		Everything else (Key Vault, the token exchange assertion):
		  The token comes straight from the user-assigned managed identity, in the home tenant.

		No secret is involved in either path. Tokens are cached per tenant and resource until five
		minutes before they expire.

	.PARAMETER Resource
		The resource (audience), e.g. 'https://graph.microsoft.com' or 'https://vault.azure.net'.

	.PARAMETER TenantId
		The tenant the token is for. Defaults to the home tenant. Only Graph tokens can be requested
		for another tenant.

	.EXAMPLE
		PS C:\> Get-SrAccessToken -Resource 'https://graph.microsoft.com' -TenantId $customerTenantId

		Returns a Graph token of the rotation app in the customer tenant.
	#>
	[OutputType([string])]
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]
		$Resource,

		[string]
		$TenantId
	)

	$config = Get-SrConfig
	if (-not $TenantId) { $TenantId = $config.HomeTenantId }
	if (-not $script:SrTokenCache) { $script:SrTokenCache = @{} }

	$isGraph = $Resource.TrimEnd('/') -eq 'https://graph.microsoft.com'
	if (-not $isGraph -and $TenantId -ne $config.HomeTenantId) {
		throw "Only Microsoft Graph tokens can be requested for another tenant, not '$Resource'."
	}

	$cacheKey = '{0}|{1}' -f $TenantId.ToLowerInvariant(), $Resource.ToLowerInvariant()
	$cached = $script:SrTokenCache[$cacheKey]
	if ($cached -and $cached.ExpiresOn -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) { return $cached.Token }

	if ($isGraph) {
		$token = Get-SrFederatedToken -Resource $Resource -TenantId $TenantId
	}
	else {
		$token = Get-SrManagedIdentityToken -Resource $Resource
	}

	$script:SrTokenCache[$cacheKey] = $token
	$token.Token
}
