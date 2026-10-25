function Invoke-SrCredentialRenewal {
	<#
	.SYNOPSIS
		Renews the client secret or the certificate of one app.

	.DESCRIPTION
		Renews exactly one credential - called by the renewal queue for a row with RenewalState = Renewable.

		- Secret: addPassword, store the value in Key Vault (app-<appId>-secret), remove it again if Key Vault fails.
		- Certificate: create it in Key Vault (app-<appId>-cert), add it to keyCredentials, disable it again if that fails.

		The renewal runs whatever the expiry date is - an admin decided. Two exceptions:
		- Apps with the exclude tag need Force.
		- Key credentials other than X.509 authentication certificates can't be renewed.

		Never throws for a failed renewal. Returns one result object with Outcome Renewed or Failed.
		The secret value is never part of the result.

	.PARAMETER TenantId
		Tenant of the app. Must be one of the configured tenants.

	.PARAMETER AppId
		Application (client) ID.

	.PARAMETER CredentialType
		Secret or Certificate.

	.PARAMETER Force
		Renew apps with the exclude tag too.

	.EXAMPLE
		PS C:\> Invoke-SrCredentialRenewal -TenantId $tenantId -AppId $appId -CredentialType Secret

		Renews the client secret of the app.
	#>
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'CredentialType', Justification = 'The kind of credential (Secret/Certificate), not a credential')]
	[OutputType([pscustomobject])]
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]
		$TenantId,

		[Parameter(Mandatory = $true)]
		[string]
		$AppId,

		[Parameter(Mandatory = $true)]
		[string]
		$CredentialType,

		[switch]
		$Force
	)

	$config = Get-SrConfig
	$entry = [pscustomobject]@{
		TenantId       = $TenantId
		AppId          = $AppId
		AppObjectId    = ''
		DisplayName    = $AppId
		CredentialType = $CredentialType
		Outcome        = 'Failed'
		OldEndDateTime = $null
		NewEndDateTime = $null
		VaultObject    = ''
		Message        = ''
	}

	try {
		if ($AppId -notmatch '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') { throw "AppId must be a GUID - not '$AppId'." }
		if ($CredentialType -notin 'Secret', 'Certificate') { throw "CredentialType '$CredentialType' can't be renewed. Only Secret and Certificate." }
		if ($TenantId -notin $config.TenantIds) { throw "Tenant '$TenantId' is not configured." }

		$uri = "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$AppId'&`$select=id,appId,displayName,tags,passwordCredentials,keyCredentials"
		$application = @(Invoke-SrRestRequest -Uri $uri -TenantId $TenantId -All) | Select-Object -First 1
		if (-not $application) { throw "No app registration with app ID $AppId in tenant $TenantId." }
		$entry.AppObjectId = $application.id
		$entry.DisplayName = $application.displayName

		if (@($application.tags) -contains $config.ExcludeTag -and -not $Force) {
			throw "The app has the tag '$($config.ExcludeTag)'. Set Force = true in the row to renew anyway."
		}

		$decision = Get-SrCredentialDecision -Application $application -TenantId $TenantId -Config $config |
			Where-Object CredentialType -eq $CredentialType
		if (-not $decision) {
			# The app has no credential of this type yet. Renewing means: add the first one.
			$decision = [pscustomobject]@{
				TenantId = $TenantId; AppObjectId = $application.id; AppId = $application.appId; DisplayName = $application.displayName
				CredentialType = $CredentialType; NewestEndDateTime = $null; DaysLeft = $null; Decision = 'None'; Reason = "The app has no $CredentialType yet."
			}
		}
		$entry.OldEndDateTime = $decision.NewestEndDateTime
		Write-Host "Renewal approved: $($application.displayName) ($AppId) | $CredentialType | tenant $TenantId | state before: $($decision.Decision)"

		if ($CredentialType -eq 'Secret') { $new = New-SrAppSecret -Decision $decision -Config $config }
		else { $new = New-SrAppCertificate -Decision $decision -Config $config }

		$entry.Outcome = 'Renewed'
		$entry.NewEndDateTime = $new.EndDateTime
		$entry.VaultObject = $new.VaultObject
		$entry.Message = "Renewed on approval (state before: $($decision.Decision)). New credential stored in Key Vault."
	}
	catch {
		$entry.Outcome = 'Failed'
		$entry.Message = "Renewal failed: $_"
	}

	Write-Host ("{0} | {1} ({2}) | {3} | {4}" -f $entry.Outcome, $entry.DisplayName, $entry.AppId, $entry.CredentialType, $entry.Message)
	$entry
}
