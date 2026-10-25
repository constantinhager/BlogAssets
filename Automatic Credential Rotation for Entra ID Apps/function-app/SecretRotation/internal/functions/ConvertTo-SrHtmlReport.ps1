function ConvertTo-SrHtmlReport {
	<#
	.SYNOPSIS
		Builds the HTML body of the notification mail.

	.DESCRIPTION
		Builds the HTML body of the notification mail. For every credential that waits for approval,
		the mail names the row in the renewal state table and the command that sets it to Renewable.

	.PARAMETER Result
		The result objects to report.

	.PARAMETER Title
		The headline.

	.PARAMETER Kind
		Check (daily report) or Renewal (result of an approved renewal).

	.PARAMETER Config
		The configuration (Get-SrConfig).

	.EXAMPLE
		PS C:\> ConvertTo-SrHtmlReport -Result $relevant -Title $subject -Kind Check -Config $config

		Returns the HTML.
	#>
	[OutputType([string])]
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[object[]]
		$Result,

		[Parameter(Mandatory = $true)]
		[string]
		$Title,

		[ValidateSet('Check', 'Renewal')]
		[string]
		$Kind = 'Check',

		[Parameter(Mandatory = $true)]
		$Config
	)

	$enc = { param ($Text) [System.Net.WebUtility]::HtmlEncode("$Text") }
	$order = @{ Failed = 0; InvalidState = 0; ApprovalRequired = 1; Renewed = 1; Stale = 2; Excluded = 3; Unsupported = 4 }
	$colors = @{ Failed = '#c50f1f'; InvalidState = '#c50f1f'; Renewed = '#107c10'; ApprovalRequired = '#0f6cbd' }
	$labels = @{ ApprovalRequired = 'Waiting for approval'; InvalidState = 'Unknown RenewalState' }

	$rows = foreach ($item in ($Result | Sort-Object { $order[$_.Outcome] }, DisplayName)) {
		$color = $colors[$item.Outcome]
		if (-not $color) { $color = '#8a6100' }
		$label = $labels[$item.Outcome]
		if (-not $label) { $label = $item.Outcome }
		$old = ''; if ($item.OldEndDateTime) { $old = $item.OldEndDateTime.ToString('yyyy-MM-dd') }
		$new = ''; if ($item.NewEndDateTime) { $new = $item.NewEndDateTime.ToString('yyyy-MM-dd') }

		$details = & $enc $item.Message
		if ($item.Outcome -in 'ApprovalRequired', 'Failed', 'InvalidState' -and $item.RowKey) {
			$command = "./scripts/Set-SecretRotationState.ps1 -StorageAccountName $($Config.StateStorageAccount) -TenantId $($item.TenantId) -AppId $($item.AppId) -CredentialType $($item.CredentialType) -State Renewable"
			$details += '<br><span style="color:#616161">Approve: set <b>RenewalState</b> to <b>Renewable</b> in table {0}, PartitionKey {1}, RowKey {2} - or run:</span><br><code style="font-size:11px">{3}</code>' -f (& $enc $Config.StateTable), (& $enc $item.TenantId), (& $enc $item.RowKey), (& $enc $command)
		}

		'<tr><td style="color:{0};font-weight:600">{1}</td><td>{2}<br><span style="color:#616161;font-size:12px">{3}<br>tenant {4}</span></td><td>{5}</td><td>{6}</td><td>{7}</td><td style="font-size:12px">{8}</td></tr>' -f $color,
		(& $enc $label), (& $enc $item.DisplayName), (& $enc $item.AppId), (& $enc $item.TenantId), (& $enc $item.CredentialType), $old, $new, $details
	}

	if ($Kind -eq 'Check') {
		$intro = 'Nothing was renewed. Credentials that expire within {0} days wait for your approval in the renewal state table <b>{1}</b> (storage account <b>{2}</b>). Set <b>RenewalState</b> to <b>Renewable</b> to renew - within 15 minutes - or to <b>Declined</b> to stop the reminder. Old credentials stay valid until they expire.' -f $Config.ThresholdDays, (& $enc $Config.StateTable), (& $enc $Config.StateStorageAccount)
	}
	else {
		$intro = 'Approved renewals from the state table. The new credential is a new version of <code>app-&lt;appId&gt;-secret</code> or <code>app-&lt;appId&gt;-cert</code> in Key Vault <b>{0}</b>. The old credential stays on the app until it expires.' -f (& $enc $Config.KeyVaultName)
	}
	$settings = 'Threshold: {0} days &middot; new secrets: {1} days &middot; new certificates: {2} months &middot; Key Vault: {3}' -f $Config.ThresholdDays, $Config.SecretValidityDays, $Config.CertificateValidityMonths, (& $enc $Config.KeyVaultName)

	@"
<html><body style="font-family:Segoe UI,Arial,sans-serif;font-size:14px;color:#242424">
<h2 style="font-weight:600">$(& $enc $Title)</h2>
<p>$intro</p>
<table cellpadding="6" cellspacing="0" style="border-collapse:collapse;border:1px solid #e0e0e0">
<tr style="background:#f5f5f5;text-align:left"><th>Status</th><th>App</th><th>Type</th><th>Expires</th><th>New expiry</th><th>Details</th></tr>
$($rows -join "`n")
</table>
<p style="color:#616161;font-size:12px">$settings</p>
</body></html>
"@
}
