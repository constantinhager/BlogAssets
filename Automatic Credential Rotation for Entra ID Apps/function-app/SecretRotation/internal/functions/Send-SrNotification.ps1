function Send-SrNotification {
	<#
	.SYNOPSIS
		Informs the admins by mail.

	.DESCRIPTION
		Sends a mail (Graph sendMail) to SR_MAIL_RECIPIENTS. Two kinds:

		Check    - the daily report: which credentials wait for approval (RenewalState = Pending), which
		           renewals failed, which RenewalState values are unknown, and which credentials need
		           attention (excluded, stale, unsupported). Nothing is sent if all is fine.
		Renewal  - the results of one run of the renewal queue (renewed or failed).

		Without SR_MAIL_SENDER / SR_MAIL_RECIPIENTS nothing is sent. The results are in the function
		logs and in the HTTP report either way.

	.PARAMETER Result
		The result objects.

	.PARAMETER Kind
		Check or Renewal.

	.PARAMETER Config
		The configuration (Get-SrConfig).

	.EXAMPLE
		PS C:\> Send-SrNotification -Result $results -Kind Check -Config $config

		Sends the daily report.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[AllowEmptyCollection()]
		[object[]]
		$Result,

		[Parameter(Mandatory = $true)]
		[ValidateSet('Check', 'Renewal')]
		[string]
		$Kind,

		[Parameter(Mandatory = $true)]
		$Config
	)

	$relevant = @($Result | Where-Object Outcome -in 'ApprovalRequired', 'Renewed', 'Failed', 'InvalidState', 'Excluded', 'Stale', 'Unsupported')
	if ($relevant.Count -eq 0) {
		Write-Host 'Nothing expires, nothing needs attention - no mail sent.'
		return
	}

	if ($Kind -eq 'Check') {
		$approval = @($relevant | Where-Object Outcome -eq 'ApprovalRequired').Count
		$failed = @($relevant | Where-Object Outcome -eq 'Failed').Count
		$attention = $relevant.Count - $approval - $failed
		$subject = 'Entra ID app credentials: {0} waiting for approval, {1} need attention, {2} failed' -f $approval, $attention, $failed
	}
	elseif ($relevant.Count -eq 1) {
		$item = $relevant[0]
		$subject = 'Entra ID app credential {0}: {1} ({2})' -f $item.Outcome.ToLowerInvariant(), $item.DisplayName, $item.CredentialType
	}
	else {
		$renewed = @($relevant | Where-Object Outcome -eq 'Renewed').Count
		$subject = 'Entra ID app credentials: {0} renewed, {1} failed' -f $renewed, ($relevant.Count - $renewed)
	}

	if (-not ($Config.MailSender -and $Config.MailRecipients.Count -gt 0)) {
		Write-Host "No mail configured. $subject"
		return
	}
	try {
		Send-SrMail -Subject $subject -Html (ConvertTo-SrHtmlReport -Result $relevant -Title $subject -Kind $Kind -Config $Config) -Config $Config
		Write-Host "Mail sent to $($Config.MailRecipients -join ', '): $subject"
	}
	catch { Write-Warning "Sending the mail failed: $_" }
}
