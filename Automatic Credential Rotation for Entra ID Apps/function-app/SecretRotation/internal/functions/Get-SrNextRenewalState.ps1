function Get-SrNextRenewalState {
	<#
	.SYNOPSIS
		Decides how the daily check changes the RenewalState of a row in the state table.

	.DESCRIPTION
		RenewalState is the column admins edit. The daily check only moves it in a few safe cases and
		never touches a row an admin just approved. Pure logic, no API calls.

		Values:
		  None        nothing to do
		  Pending     expires soon, waits for an admin          (set by the check)
		  Renewable   approved - renew it                       (set by an admin)
		  InProgress  the renewal queue is working on it        (set by the queue)
		  Renewed     renewed, see RenewedOn / NewExpiresOn     (set by the queue)
		  Failed      renewal failed, see RenewalMessage        (set by the queue) - set Renewable again to retry
		  Declined    don't renew, no reminders                 (set by an admin)

		Rules of the daily check:
		- Renewable is never changed.
		- InProgress for longer than -StuckAfterMinutes becomes Failed (the queue run was interrupted).
		- ApprovalRequired + None/Renewed/empty -> Pending.
		- Ok + Pending/Failed/Declined -> None (someone renewed it elsewhere, nothing to decide anymore).
		- Unknown values (typos) are not changed; they are reported as InvalidState.

		Returns a hashtable: State (the new value, or $null for "no change") and Invalid ($true for unknown values).
		Values are compared case-insensitively.

	.PARAMETER CurrentState
		The RenewalState in the table ($null/empty for a new row).

	.PARAMETER CheckResult
		The decision of the check: Ok, ApprovalRequired, Excluded, Stale or Unsupported.

	.PARAMETER RenewalStartedOn
		When the queue set the row to InProgress.

	.PARAMETER Now
		Reference time. Used by tests.

	.PARAMETER StuckAfterMinutes
		After how many minutes InProgress counts as interrupted.

	.EXAMPLE
		PS C:\> Get-SrNextRenewalState -CurrentState 'None' -CheckResult 'ApprovalRequired'

		Returns @{ State = 'Pending'; Invalid = $false }.
	#>
	[OutputType([hashtable])]
	[CmdletBinding()]
	param (
		[AllowEmptyString()]
		[AllowNull()]
		[string]
		$CurrentState,

		[Parameter(Mandatory = $true)]
		[string]
		$CheckResult,

		$RenewalStartedOn,

		[DateTimeOffset]
		$Now = [DateTimeOffset]::UtcNow,

		[int]
		$StuckAfterMinutes = 60
	)

	$known = 'None', 'Pending', 'Renewable', 'InProgress', 'Renewed', 'Failed', 'Declined'
	$state = "$CurrentState".Trim()

	if ($state -and $state -notin $known) { return @{ State = $null; Invalid = $true } }
	if ($state -eq 'Renewable') { return @{ State = $null; Invalid = $false } }
	if ($state -eq 'InProgress') {
		$started = $null
		if ($RenewalStartedOn) { try { $started = [DateTimeOffset]$RenewalStartedOn } catch { $started = $null } }
		if (-not $started -or $started -lt $Now.AddMinutes(-$StuckAfterMinutes)) { return @{ State = 'Failed'; Invalid = $false } }
		return @{ State = $null; Invalid = $false }
	}

	if ($CheckResult -eq 'ApprovalRequired' -and (-not $state -or $state -in 'None', 'Renewed')) { return @{ State = 'Pending'; Invalid = $false } }
	if ($CheckResult -eq 'Ok' -and $state -in 'Pending', 'Failed', 'Declined') { return @{ State = 'None'; Invalid = $false } }
	if (-not $state) { return @{ State = 'None'; Invalid = $false } }
	@{ State = $null; Invalid = $false }
}
