function Get-AppCredentialReport {
	<#
	.SYNOPSIS
		Lists the client secrets and certificates of all app registrations and which ones wait for approval.

	.DESCRIPTION
		HTTP endpoint (GET /api/Get-AppCredentialReport). Read-only - nothing is created or changed.
		Returns one row per credential, with the decision for its app and type and the RenewalState from
		the state table. A credential that expires within the threshold shows Decision = ApprovalRequired:
		it is not renewed until an admin sets RenewalState = Renewable.

		Parameters come from the query string, so all of them are strings.

	.PARAMETER State
		Filter by credential state: All (default), Expiring, Expired, Valid. 'Expiring' includes 'Expired'.

	.PARAMETER ThresholdDays
		Override SR_THRESHOLD_DAYS for this report.

	.PARAMETER TenantId
		Only report this tenant. Default: all configured tenants.

	.EXAMPLE
		PS C:\> Get-AppCredentialReport -State Expiring -ThresholdDays 60

		Lists everything that expires within 60 days.
	#>
	[CmdletBinding()]
	param (
		[string]
		$State = 'All',

		[string]
		$ThresholdDays,

		[string]
		$TenantId
	)

	if ($State -notin 'All', 'Expiring', 'Expired', 'Valid') {
		throw "State must be All, Expiring, Expired or Valid - not '$State'."
	}

	$config = Get-SrConfig
	if ($ThresholdDays) {
		$days = 0
		if (-not [int]::TryParse($ThresholdDays, [ref]$days) -or $days -lt 0) { throw "ThresholdDays must be a positive number - not '$ThresholdDays'." }
		$config = $config.PSObject.Copy()
		$config.ThresholdDays = $days
	}

	$tenants = $config.TenantIds
	if ($TenantId) {
		if ($TenantId -notin $config.TenantIds) { throw "Tenant '$TenantId' is not configured." }
		$tenants = @($TenantId)
	}

	foreach ($tenant in $tenants) {
		$states = @{}
		try {
			foreach ($row in Invoke-SrTableRequest -Operation Query -Filter "PartitionKey eq '$tenant'") { $states[$row.RowKey] = $row.RenewalState }
		}
		catch { Write-Warning "Reading the state table failed: $_" }

		foreach ($application in Get-SrApplication -TenantId $tenant) {
			foreach ($decision in Get-SrCredentialDecision -Application $application -TenantId $tenant -Config $config) {
				foreach ($credential in $decision.Credentials) {
					if ($State -eq 'Expiring' -and $credential.State -eq 'Valid') { continue }
					if ($State -in 'Expired', 'Valid' -and $credential.State -ne $State) { continue }

					[pscustomobject]@{
						TenantId       = $tenant
						DisplayName    = $decision.DisplayName
						AppId          = $decision.AppId
						CredentialType = $decision.CredentialType
						CredentialName = $credential.DisplayName
						KeyId          = $credential.KeyId
						Hint           = $credential.Hint
						EndDateTime    = $credential.EndDateTime.ToString('o')
						DaysLeft       = $credential.DaysLeft
						State          = $credential.State
						Decision       = $decision.Decision
						RenewalState   = $states['{0}_{1}' -f $decision.AppId, $decision.CredentialType]
						Reason         = $decision.Reason
					}
				}
			}
		}
	}
}
