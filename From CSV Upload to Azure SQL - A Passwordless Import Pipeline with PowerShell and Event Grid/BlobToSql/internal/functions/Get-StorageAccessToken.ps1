function Get-StorageAccessToken {
	<#
	.SYNOPSIS
		Returns an access token for Azure Storage.

	.DESCRIPTION
		In the Function App the token comes from the managed identity endpoint (IDENTITY_ENDPOINT /
		IDENTITY_HEADER). Without a client_id this is the system-assigned identity, which holds the
		storage roles. Outside Azure the Azure CLI login is used.

		The token is cached per runspace until five minutes before it expires.

	.EXAMPLE
		PS C:\> Get-StorageAccessToken

		Returns a bearer token for https://storage.azure.com/.
	#>
	[CmdletBinding()]
	[OutputType([string])]
	param ()

	if ($script:StorageToken -and $script:StorageTokenExpiresOn -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
		return $script:StorageToken
	}

	$resource = 'https://storage.azure.com/'
	if ($env:IDENTITY_ENDPOINT) {
		$tokenParam = @{
			Uri     = '{0}?resource={1}&api-version=2019-08-01' -f $env:IDENTITY_ENDPOINT, [Uri]::EscapeDataString($resource)
			Headers = @{ 'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER }
		}
		$response = Invoke-RestMethod @tokenParam
		$script:StorageToken = $response.access_token
	} else {
		$azArgs = @(
			'account', 'get-access-token'
			'--resource', $resource
			'--output', 'json'
		)
		$response = az @azArgs | ConvertFrom-Json
		if ($LASTEXITCODE -ne 0) {
			throw "az account get-access-token failed with exit code $LASTEXITCODE"
		}
		$script:StorageToken = $response.accessToken
	}
	$script:StorageTokenExpiresOn = [DateTimeOffset]::FromUnixTimeSeconds([long]$response.expires_on)
	$script:StorageToken
}
