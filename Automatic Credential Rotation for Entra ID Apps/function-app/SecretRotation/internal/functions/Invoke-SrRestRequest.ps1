function Invoke-SrRestRequest {
	<#
	.SYNOPSIS
		Calls Microsoft Graph or Azure Key Vault with a managed identity token.

	.DESCRIPTION
		One wrapper for all Graph and Key Vault calls:
		- picks the token by host (graph.microsoft.com or *.vault.azure.net) and refuses every other host
		- retries on 429 and 5xx, honouring Retry-After
		- follows @odata.nextLink (Graph) and nextLink (Key Vault) with -All
		- turns error responses into readable exceptions

	.PARAMETER Uri
		The full request URI.

	.PARAMETER Method
		The HTTP method. Defaults to GET.

	.PARAMETER Body
		The request body. Hashtables and objects are converted to JSON.

	.PARAMETER TenantId
		The tenant of the token (Graph only). Defaults to the home tenant.

	.PARAMETER All
		Follow the paging links and return all items of the 'value' collections.

	.PARAMETER AllowNotFound
		Return $null on 404 instead of throwing.

	.PARAMETER MaxRetry
		How often a throttled or failed request is retried.

	.EXAMPLE
		PS C:\> Invoke-SrRestRequest -Uri 'https://graph.microsoft.com/v1.0/applications?$top=999' -All

		Returns all app registrations of the home tenant.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]
		$Uri,

		[ValidateSet('GET', 'POST', 'PATCH', 'PUT', 'DELETE')]
		[string]
		$Method = 'GET',

		$Body,

		[string]
		$TenantId,

		[switch]
		$All,

		[switch]
		$AllowNotFound,

		[int]
		$MaxRetry = 4
	)

	$targetHost = ([uri]$Uri).Host
	$resource = switch -Regex ($targetHost) {
		'^graph\.microsoft\.com$' { 'https://graph.microsoft.com'; break }
		'^[a-z0-9-]+\.vault\.azure\.net$' { 'https://vault.azure.net'; break }
		default { throw "Refusing to send a token to '$targetHost'. Only Microsoft Graph and Azure Key Vault are allowed." }
	}
	if ($resource -eq 'https://vault.azure.net' -and $TenantId) {
		throw 'Key Vault calls always use the home tenant.'
	}

	$jsonBody = $null
	if ($null -ne $Body) {
		if ($Body -is [string]) { $jsonBody = $Body }
		else { $jsonBody = $Body | ConvertTo-Json -Depth 20 -Compress }
	}

	$items = [System.Collections.Generic.List[object]]::new()
	$nextUri = $Uri
	while ($nextUri) {
		$attempt = 0
		while ($true) {
			$attempt++
			$headers = @{
				Authorization = 'Bearer {0}' -f (Get-SrAccessToken -Resource $resource -TenantId $TenantId)
			}
			$param = @{
				Method                  = $Method
				Uri                     = $nextUri
				Headers                 = $headers
				SkipHttpErrorCheck      = $true
				StatusCodeVariable      = 'statusCode'
				ResponseHeadersVariable = 'responseHeaders'
				ErrorAction             = 'Stop'
			}
			if ($null -ne $jsonBody) {
				$param.Body = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
				$param.ContentType = 'application/json; charset=utf-8'
			}
			$content = Invoke-RestMethod @param

			if (($statusCode -eq 429 -or $statusCode -ge 500) -and $attempt -le $MaxRetry) {
				$delay = [math]::Min(60, [math]::Pow(2, $attempt))
				if ($responseHeaders -and $responseHeaders['Retry-After']) {
					$retryAfter = 0
					if ([int]::TryParse("$($responseHeaders['Retry-After'])", [ref]$retryAfter)) { $delay = $retryAfter }
				}
				Write-Warning "$Method $targetHost returned $statusCode. Retry $attempt/$MaxRetry in $delay seconds."
				Start-Sleep -Seconds $delay
				continue
			}
			break
		}

		if ($statusCode -eq 404 -and $AllowNotFound) { return $null }
		if ($statusCode -ge 400) {
			$code = $content.error.code
			$message = $content.error.message
			if (-not $message) { $message = "$content" }
			$path = ([uri]$nextUri).AbsolutePath
			throw "$Method $targetHost$path failed: $statusCode $code $message"
		}

		if (-not $All) { return $content }

		foreach ($item in $content.value) { $items.Add($item) }
		$nextUri = $content.'@odata.nextLink'
		if (-not $nextUri) { $nextUri = $content.nextLink }
	}
	$items.ToArray()
}
