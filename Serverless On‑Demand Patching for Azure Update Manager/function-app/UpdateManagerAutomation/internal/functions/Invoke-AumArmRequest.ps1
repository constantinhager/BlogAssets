function Invoke-AumArmRequest {
	<#
	.SYNOPSIS
		Sends a request to Azure Resource Manager (management.azure.com) via plain REST.

	.DESCRIPTION
		Thin wrapper around Invoke-RestMethod:
		- Adds the Managed Identity bearer token
		- Adds the api-version
		- Retries on throttling (429) and transient server errors (5xx), honoring Retry-After
		- Follows nextLink paging when -All is specified
		- Turns ARM error bodies into readable exceptions

		Returns an object with StatusCode, Headers and Content.
		With -All, returns the combined 'value' items of all pages instead.

	.PARAMETER Path
		Resource path below https://management.azure.com (e.g. '/subscriptions/.../assessPatches')
		or a full https://management.azure.com/... URL.

	.PARAMETER ApiVersion
		The api-version to use. Ignored if the path already contains one (e.g. nextLink).

	.PARAMETER Method
		HTTP method. Defaults to GET.

	.PARAMETER Body
		Request body. Hashtables / objects are converted to JSON.

	.PARAMETER All
		Follow nextLink and return all 'value' items of a list call.

	.PARAMETER MaxRetry
		How often to retry on 429 / 5xx. Defaults to 4.

	.EXAMPLE
		PS C:\> Invoke-AumArmRequest -Path "/subscriptions/$sub/providers/Microsoft.Maintenance/maintenanceConfigurations" -ApiVersion '2023-04-01' -All

		Lists all maintenance configurations in the subscription.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]
		$Path,

		[string]
		$ApiVersion,

		[ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
		[string]
		$Method = 'GET',

		$Body,

		[switch]
		$All,

		[int]
		$MaxRetry = 4
	)

	$uri = if ($Path -match '^https://') { $Path } else { '{0}/{1}' -f $script:ArmEndpoint, $Path.TrimStart('/') }
	if ($uri -notmatch '[?&]api-version=' -and $ApiVersion) {
		$separator = if ($uri.Contains('?')) { '&' } else { '?' }
		$uri = "$uri$($separator)api-version=$ApiVersion"
	}

	# Never send the Managed Identity token anywhere but ARM.
	if (([uri]$uri).Host -ne ([uri]$script:ArmEndpoint).Host) {
		throw "Refusing to send an ARM token to '$(([uri]$uri).Host)'."
	}

	$jsonBody = $null
	if ($null -ne $Body) {
		$jsonBody = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 20 -Compress }
	}

	$items = [System.Collections.Generic.List[object]]::new()
	$attempt = 0

	while ($uri) {
		$headers = @{ Authorization = "Bearer $(Get-AumAccessToken -Resource "$($script:ArmEndpoint)/")" }
		$param = @{
			Method                  = $Method
			Uri                     = $uri
			Headers                 = $headers
			ContentType             = 'application/json'
			SkipHttpErrorCheck      = $true
			ResponseHeadersVariable = 'responseHeaders'
			StatusCodeVariable      = 'statusCode'
			ErrorAction             = 'Stop'
		}
		if ($jsonBody) { $param.Body = $jsonBody }

		$content = Invoke-RestMethod @param

		# Throttled or transient error -> wait and retry
		if (($statusCode -eq 429 -or $statusCode -ge 500) -and $attempt -lt $MaxRetry) {
			$attempt++
			$wait = 5 * $attempt
			if ($responseHeaders['Retry-After']) { $wait = [int]@($responseHeaders['Retry-After'])[0] }
			Write-Warning "ARM returned $statusCode for $Method $uri - retry $attempt/$MaxRetry in $wait seconds"
			Start-Sleep -Seconds $wait
			continue
		}
		$attempt = 0

		if ($statusCode -ge 400) {
			$errorCode = $content.error.code
			$errorMessage = $content.error.message
			if (-not $errorMessage) { $errorMessage = $content | ConvertTo-Json -Depth 5 -Compress }
			# Resource Graph and others put the actual reason (e.g. ParserFailure line/token) into error.details
			if ($content.error.details) { $errorMessage += " Details: $($content.error.details | ConvertTo-Json -Depth 5 -Compress)" }
			throw "ARM request failed: $Method $uri -> $statusCode $errorCode $errorMessage"
		}

		if (-not $All) {
			return [pscustomobject]@{
				StatusCode = $statusCode
				Headers    = $responseHeaders
				Content    = $content
			}
		}

		foreach ($item in $content.value) { $items.Add($item) }
		$uri = $content.nextLink
	}

	$items.ToArray()
}
