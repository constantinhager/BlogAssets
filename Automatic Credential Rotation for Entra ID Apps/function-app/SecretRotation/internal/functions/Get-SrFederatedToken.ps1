function Get-SrFederatedToken {
	<#
	.SYNOPSIS
		Exchanges a managed identity token for a token of the rotation app in a tenant.

	.DESCRIPTION
		Managed identity as federated identity credential (FIC). Used for every Graph call, in the home
		tenant as well as in customer tenants:

		1. Get a token of the user-assigned managed identity for the audience 'api://AzureADTokenExchange'.
		2. Send it as client_assertion to the token endpoint of the target tenant, together with the
		   client ID of the multi-tenant rotation app (SR_ROTATION_APP_ID).
		3. Entra ID returns a normal access token for the app in the target tenant.

		Requirements: the app has a federated identity credential with
		issuer   = https://login.microsoftonline.com/<home tenant>/v2.0
		subject  = object (principal) ID of the user-assigned managed identity
		audience = api://AzureADTokenExchange
		and an admin of the target tenant (home tenant included) has consented to the app.

		Local development: there is no managed identity, so there is nothing to exchange. Outside of
		Azure the token comes from the Azure CLI instead - with the permissions of the signed-in user.

	.PARAMETER Resource
		The resource in the target tenant, e.g. 'https://graph.microsoft.com'.

	.PARAMETER TenantId
		The target tenant.

	.EXAMPLE
		PS C:\> Get-SrFederatedToken -Resource 'https://graph.microsoft.com' -TenantId $customerTenantId

		Returns a Graph token of the rotation app for the customer tenant.
	#>
	[OutputType([pscustomobject])]
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]
		$Resource,

		[Parameter(Mandatory = $true)]
		[string]
		$TenantId
	)

	$config = Get-SrConfig

	if (-not ($env:IDENTITY_ENDPOINT -and $env:IDENTITY_HEADER)) {
		Write-Warning "No managed identity endpoint - using the Azure CLI account for '$Resource' in tenant $TenantId (local development)."
		$json = az account get-access-token --resource $Resource --tenant $TenantId --output json 2>$null
		if ($LASTEXITCODE -ne 0 -or -not $json) { throw "'az account get-access-token' failed for tenant $TenantId. Run 'az login --tenant $TenantId'." }
		$cliToken = $json | ConvertFrom-Json
		return [pscustomobject]@{
			Token     = $cliToken.accessToken
			ExpiresOn = [DateTimeOffset]::FromUnixTimeSeconds([long]$cliToken.expires_on)
		}
	}

	# Step 1: the assertion (cached like every other managed identity token)
	$assertion = Get-SrAccessToken -Resource 'api://AzureADTokenExchange'

	# Step 2: exchange it in the target tenant
	$body = @{
		client_id             = $config.RotationAppId
		scope                 = '{0}/.default' -f $Resource.TrimEnd('/')
		grant_type            = 'client_credentials'
		client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
		client_assertion      = $assertion
	}
	try {
		$response = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
			-Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
	}
	catch {
		# The token endpoint answers with error + error_description (AADSTS code) - that's the useful part
		$detail = $_.ErrorDetails.Message
		if ($detail) {
			try { $detail = ($detail | ConvertFrom-Json).error_description } catch { $null = $_ }
		}
		throw "Token exchange for tenant $TenantId failed (app $($config.RotationAppId)): $detail $_"
	}

	[pscustomobject]@{
		Token     = $response.access_token
		ExpiresOn = [DateTimeOffset]::UtcNow.AddSeconds([int]$response.expires_in)
	}
}
