function Get-SrManagedIdentityToken {
	<#
	.SYNOPSIS
		Requests a token from the managed identity endpoint of the Function App.

	.DESCRIPTION
		Requests a token from the managed identity endpoint of the Function App.
		Uses the user-assigned identity from SR_MANAGED_IDENTITY_CLIENT_ID.

		Outside of Azure (local development) there is no identity endpoint.
		Then the token comes from the Azure CLI ('az account get-access-token').

	.PARAMETER Resource
		The resource (audience) of the token.

	.EXAMPLE
		PS C:\> Get-SrManagedIdentityToken -Resource 'https://vault.azure.net'

		Returns token and expiry for Key Vault.
	#>
	[OutputType([pscustomobject])]
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]
		$Resource
	)

	$config = Get-SrConfig

	if ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER) {
		$query = 'resource={0}&api-version=2019-08-01' -f [uri]::EscapeDataString($Resource)
		if ($config.ManagedIdentityClientId) {
			$query += '&client_id={0}' -f $config.ManagedIdentityClientId
		}
		$response = Invoke-RestMethod -Uri ('{0}?{1}' -f $env:IDENTITY_ENDPOINT, $query) -Headers @{
			'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER
		} -ErrorAction Stop

		return [pscustomobject]@{
			Token     = $response.access_token
			ExpiresOn = [DateTimeOffset]::FromUnixTimeSeconds([long]$response.expires_on)
		}
	}

	# Local development: use the signed-in Azure CLI account
	$json = az account get-access-token --resource $Resource --tenant $config.HomeTenantId --output json 2>$null
	if ($LASTEXITCODE -ne 0 -or -not $json) {
		throw "No managed identity endpoint found and 'az account get-access-token' failed for '$Resource'. Run 'az login' for local development."
	}
	$cliToken = $json | ConvertFrom-Json
	[pscustomobject]@{
		Token     = $cliToken.accessToken
		ExpiresOn = [DateTimeOffset]::FromUnixTimeSeconds([long]$cliToken.expires_on)
	}
}
