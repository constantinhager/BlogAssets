function Get-AumAccessToken {
	<#
	.SYNOPSIS
		Returns an Entra ID access token for the given resource, using the Function App's Managed Identity.

	.DESCRIPTION
		Uses the identity endpoint that App Service / Azure Functions injects into every app
		with a Managed Identity (IDENTITY_ENDPOINT + IDENTITY_HEADER). No Az module, no secret.

		Tokens are cached per resource and renewed five minutes before they expire.

		For local development (func start) there is no identity endpoint.
		In that case the function falls back to the Azure CLI, if it is signed in.

	.PARAMETER Resource
		The resource (audience) to request the token for.
		E.g. 'https://management.azure.com/' or 'https://storage.azure.com/'.

	.PARAMETER ClientId
		Client ID of a user-assigned Managed Identity. Leave empty for the system-assigned identity.

	.EXAMPLE
		PS C:\> Get-AumAccessToken -Resource 'https://management.azure.com/'

		Returns a token for Azure Resource Manager.
	#>
	[OutputType([string])]
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]
		$Resource,

		[string]
		$ClientId = $env:AUM_IDENTITY_CLIENT_ID
	)

	$cached = $script:TokenCache[$Resource]
	if ($cached -and $cached.ExpiresOn -gt (Get-Date).ToUniversalTime().AddMinutes(5)) {
		return $cached.Token
	}

	if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
		$uri = '{0}?resource={1}&api-version=2019-08-01' -f $env:IDENTITY_ENDPOINT, [uri]::EscapeDataString($Resource)
		if ($ClientId) { $uri += "&client_id=$ClientId" }

		$response = Invoke-RestMethod -Method Get -Uri $uri -Headers @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER } -ErrorAction Stop
		$token = $response.access_token
		$expiresOn = [DateTimeOffset]::FromUnixTimeSeconds([int64]$response.expires_on).UtcDateTime
	}
	elseif (Get-Command -Name az -ErrorAction Ignore) {
		# Local development only: use the signed-in Azure CLI account.
		$response = az account get-access-token --resource $Resource --output json | ConvertFrom-Json
		if (-not $response.accessToken) { throw "Azure CLI did not return a token for $Resource. Run 'az login' first." }
		$token = $response.accessToken
		$expiresOn = ([datetime]$response.expiresOn).ToUniversalTime()
	}
	else {
		throw "No Managed Identity endpoint found (IDENTITY_ENDPOINT) and no Azure CLI available. Cannot get a token for $Resource."
	}

	$script:TokenCache[$Resource] = @{ Token = $token; ExpiresOn = $expiresOn }
	$token
}
