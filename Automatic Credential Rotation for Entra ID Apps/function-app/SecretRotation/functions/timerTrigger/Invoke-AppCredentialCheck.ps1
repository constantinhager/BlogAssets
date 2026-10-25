function Invoke-AppCredentialCheck {
	<#
	.SYNOPSIS
		Checks all app registrations and reports expiring client secrets and certificates. Renews nothing.

	.DESCRIPTION
		Timer trigger (daily). For every tenant in the configuration:

		1. List all app registrations with their secrets and certificates (Microsoft Graph).
		2. Copy the public part of existing certificates to Key Vault (once per certificate).
		3. Decide per app and credential type (Get-SrCredentialDecision).
		4. Write the result into the renewal state table (Sync-SrStateTable). A credential that expires
		   within the threshold gets RenewalState = Pending.
		5. Send one report by mail if something waits for approval or needs attention.

		Nothing is renewed here. An admin approves a renewal by setting RenewalState = Renewable in the
		table. The renewal queue (Invoke-AppCredentialRenewalQueue) picks it up within 15 minutes.

	.EXAMPLE
		PS C:\> Invoke-AppCredentialCheck

		Runs one check.
	#>
	[CmdletBinding()]
	param ()

	$config = Get-SrConfig -Refresh
	$results = [System.Collections.Generic.List[object]]::new()
	Write-Host ("Start: {0} tenant(s), threshold {1} days" -f $config.TenantIds.Count, $config.ThresholdDays)

	foreach ($tenantId in $config.TenantIds) {
		try {
			$applications = @(Get-SrApplication -TenantId $tenantId)
		}
		catch {
			Write-Warning "Tenant $($tenantId): listing the applications failed: $_"
			$results.Add([pscustomobject]@{
					TenantId = $tenantId; AppId = ''; AppObjectId = ''; DisplayName = "Tenant $tenantId"; CredentialType = ''
					RenewalState = ''; RowKey = ''; Outcome = 'Failed'; OldEndDateTime = $null; NewEndDateTime = $null; VaultObject = ''; Message = "Listing the applications failed: $_"
				})
			continue
		}
		Write-Host "Tenant $($tenantId): $($applications.Count) application(s)."
		$decisions = [System.Collections.Generic.List[object]]::new()

		foreach ($application in $applications) {
			# Back up the public part of existing certificates - this doesn't change anything on the app
			if ($config.BackupPublicCertificates) {
				try {
					foreach ($backup in Backup-SrPublicCertificate -Application $application -TenantId $tenantId) {
						$results.Add([pscustomobject]@{
								TenantId = $tenantId; AppId = $application.appId; AppObjectId = $application.id; DisplayName = $application.displayName
								CredentialType = 'Certificate'; Outcome = 'BackedUp'; OldEndDateTime = $null; NewEndDateTime = $null
								VaultObject = $backup.VaultObject; Message = "Public certificate $($backup.Thumbprint) copied to Key Vault."
							})
					}
				}
				catch { Write-Warning "$($application.displayName): public certificate backup failed: $_" }
			}

			foreach ($decision in Get-SrCredentialDecision -Application $application -TenantId $tenantId -Config $config) {
				$decisions.Add($decision)
			}
		}

		try {
			foreach ($entry in Sync-SrStateTable -TenantId $tenantId -Decisions $decisions.ToArray() -Config $config) {
				Write-Host ("{0} | {1} ({2}) | {3} | {4}" -f $entry.Outcome, $entry.DisplayName, $entry.AppId, $entry.CredentialType, $entry.Message)
				$results.Add($entry)
			}
		}
		catch {
			Write-Warning "Tenant $($tenantId): updating the state table failed: $_"
			$results.Add([pscustomobject]@{
					TenantId = $tenantId; AppId = ''; AppObjectId = ''; DisplayName = "Tenant $tenantId"; CredentialType = ''; RenewalState = ''; RowKey = ''
					Outcome = 'Failed'; OldEndDateTime = $null; NewEndDateTime = $null; VaultObject = ''; Message = "Updating the state table failed: $_"
				})
			# Still report what expires - the mail must not go quiet because the table is unreachable
			foreach ($decision in $decisions | Where-Object Decision -in 'ApprovalRequired', 'Excluded', 'Stale') {
				$results.Add([pscustomobject]@{
						TenantId = $tenantId; AppId = $decision.AppId; AppObjectId = $decision.AppObjectId; DisplayName = $decision.DisplayName
						CredentialType = $decision.CredentialType; RenewalState = 'Unknown'; RowKey = ('{0}_{1}' -f $decision.AppId, $decision.CredentialType)
						Outcome = $decision.Decision; OldEndDateTime = $decision.NewestEndDateTime; NewEndDateTime = $null; VaultObject = ''
						Message = "$($decision.Reason) (state table not updated)"
					})
			}
		}
	}

	Send-SrNotification -Result $results.ToArray() -Kind Check -Config $config

	$summary = $results | Group-Object Outcome | ForEach-Object { '{0}={1}' -f $_.Name, $_.Count }
	Write-Host "Done: $($summary -join ', ')"
	$tenantFailures = @($results | Where-Object { $_.Outcome -eq 'Failed' -and -not $_.AppId })
	if ($tenantFailures.Count -gt 0) {
		# Let the run show up as failed in the monitoring, after the mail went out
		throw "The check failed for $($tenantFailures.Count) tenant(s)."
	}
}
