function Sync-SrStateTable {
	<#
	.SYNOPSIS
		Writes the result of the daily check for one tenant into the renewal state table.

	.DESCRIPTION
		One row per app and credential type:
		  PartitionKey = tenant ID
		  RowKey       = <appId>_<CredentialType>   (CredentialType: Secret, Certificate, OtherKey)

		Columns written by the check: DisplayName, AppId, AppObjectId, TenantId, CredentialType, CheckResult,
		ExpiresOn, Reason, LastChanged. Columns admins edit: RenewalState (and optionally Force, Comment).

		- Info columns are only written when they change - unchanged rows cost one read per day, no write.
		- RenewalState is changed only by the rules in Get-SrNextRenewalState, and only with If-Match on the
		  ETag the check read. If an admin edited the row in the meantime, the admin wins.
		- Rows of credentials that no longer exist are deleted, unless they are Renewable or InProgress.

		Returns the entries for the daily mail: everything that waits for approval, failed renewals,
		unknown RenewalState values and credentials that need attention.

	.PARAMETER TenantId
		The tenant (partition).

	.PARAMETER Decisions
		All decisions of this tenant (Get-SrCredentialDecision), including Ok.

	.PARAMETER Config
		The configuration (Get-SrConfig).

	.EXAMPLE
		PS C:\> Sync-SrStateTable -TenantId $tenantId -Decisions $decisions -Config $config

		Updates the table and returns the mail entries.
	#>
	[OutputType([pscustomobject])]
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]
		$TenantId,

		[Parameter(Mandatory = $true)]
		[AllowEmptyCollection()]
		[object[]]
		$Decisions,

		[Parameter(Mandatory = $true)]
		$Config
	)

	$rows = @{}
	foreach ($row in Invoke-SrTableRequest -Operation Query -Filter "PartitionKey eq '$TenantId'") { $rows[$row.RowKey] = $row }
	$seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
	$now = [DateTimeOffset]::UtcNow.ToString('o')

	foreach ($decision in $Decisions) {
		$rowKey = '{0}_{1}' -f $decision.AppId, $decision.CredentialType
		$null = $seen.Add($rowKey)
		$existing = $rows[$rowKey]

		$info = [ordered]@{
			DisplayName    = "$($decision.DisplayName)"
			AppId          = "$($decision.AppId)"
			AppObjectId    = "$($decision.AppObjectId)"
			TenantId       = $TenantId
			CredentialType = "$($decision.CredentialType)"
			CheckResult    = "$($decision.Decision)"
			ExpiresOn      = $decision.NewestEndDateTime.ToString('o')
			Reason         = "$($decision.Reason)"
		}
		$infoChanged = -not $existing
		if ($existing) {
			foreach ($key in $info.Keys) {
				if ("$($existing.$key)" -cne $info[$key]) { $infoChanged = $true; break }
			}
		}

		$next = Get-SrNextRenewalState -CurrentState $existing.RenewalState -CheckResult $decision.Decision -RenewalStartedOn $existing.RenewalStartedOn
		$effective = "$($existing.RenewalState)"
		$message = "$($existing.RenewalMessage)"

		if ($next.State) {
			$properties = @{} + $info
			$properties.RenewalState = $next.State
			$properties.LastChanged = $now
			if ($next.State -eq 'Failed') {
				$message = 'The renewal was interrupted (InProgress for more than 60 minutes). Set RenewalState to Renewable to try again.'
				$properties.RenewalMessage = $message
			}
			$param = @{ Operation = 'Merge'; PartitionKey = $TenantId; RowKey = $rowKey; Properties = $properties }
			if ($existing) { $param.IfMatch = $existing.ETag }
			if (Invoke-SrTableRequest @param) { $effective = $next.State }
			else { Write-Host "Row $rowKey was changed by someone else during the check - left as it is." }
		}
		elseif ($infoChanged) {
			$properties = @{} + $info
			$properties.LastChanged = $now
			$null = Invoke-SrTableRequest -Operation Merge -PartitionKey $TenantId -RowKey $rowKey -Properties $properties
		}

		# What goes into the daily mail
		$outcome = $null
		if ($next.Invalid) {
			$outcome = 'InvalidState'
			$message = "RenewalState '$($existing.RenewalState)' is not a known value. Use Renewable to approve or Declined to stop the reminders."
		}
		elseif ($effective -eq 'Failed') { $outcome = 'Failed' }
		elseif ($decision.Decision -eq 'ApprovalRequired' -and $effective -eq 'Pending') { $outcome = 'ApprovalRequired'; $message = $decision.Reason }
		elseif ($decision.Decision -in 'Excluded', 'Stale' -and $effective -ne 'Declined') { $outcome = $decision.Decision; $message = $decision.Reason }
		elseif ($decision.Decision -eq 'Unsupported' -and $decision.DaysLeft -le $Config.ThresholdDays) { $outcome = 'Unsupported'; $message = $decision.Reason }
		if (-not $outcome) { continue }

		[pscustomobject]@{
			TenantId       = $TenantId
			AppId          = $decision.AppId
			AppObjectId    = $decision.AppObjectId
			DisplayName    = $decision.DisplayName
			CredentialType = $decision.CredentialType
			Outcome        = $outcome
			RenewalState   = $effective
			RowKey         = $rowKey
			OldEndDateTime = $decision.NewestEndDateTime
			NewEndDateTime = $null
			VaultObject    = ''
			Message        = $message
		}
	}

	# Credentials that disappeared (app deleted, credential removed)
	foreach ($rowKey in @($rows.Keys)) {
		if ($seen.Contains($rowKey)) { continue }
		if ("$($rows[$rowKey].RenewalState)" -in 'Renewable', 'InProgress') { continue }
		try { Invoke-SrTableRequest -Operation Delete -PartitionKey $TenantId -RowKey $rowKey -IfMatch $rows[$rowKey].ETag }
		catch { Write-Warning "Removing row $rowKey failed: $_" }
	}
}
