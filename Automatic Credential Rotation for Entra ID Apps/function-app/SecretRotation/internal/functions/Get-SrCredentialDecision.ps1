function Get-SrCredentialDecision {
	<#
	.SYNOPSIS
		Decides per app and credential type whether a new credential is needed.

	.DESCRIPTION
		Decides per app and credential type (client secret / certificate) whether a new credential is needed.
		This function only looks at the data. It doesn't call any API, so it is easy to test.

		Nothing is renewed automatically. 'ApprovalRequired' means: this needs a new credential. The daily
		check writes it into the renewal state table as RenewalState = Pending and waits for an admin.

		The rule looks at the credential that lives longest ("newest"), not at every single one.
		If an app has an expiring secret and a second, newer secret that is valid for months,
		someone already rolled it over - nothing to do. After an approved renewal, the next check sees
		the new credential and reports the app as Ok again.

		Decision per type:
		- Ok                newest credential expires after the threshold
		- ApprovalRequired  newest credential expires within the threshold (or expired within the grace period);
		                    waiting for an admin to approve the renewal
		- Excluded          needs a new credential, but the app has the exclude tag - only reported
		- Stale             newest credential expired longer ago than the grace period - probably unused
		- Unsupported       key credentials this function can't renew (anything but AsymmetricX509Cert/Verify)

	.PARAMETER Application
		The application object from Graph (id, appId, displayName, tags, passwordCredentials, keyCredentials).

	.PARAMETER TenantId
		The tenant of the application.

	.PARAMETER Config
		The configuration (Get-SrConfig).

	.PARAMETER Now
		The reference time. Defaults to now (UTC). Used by tests.

	.EXAMPLE
		PS C:\> Get-SrCredentialDecision -Application $app -TenantId $tenantId -Config (Get-SrConfig)

		Returns one decision per credential type the app has.
	#>
	[OutputType([pscustomobject])]
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		$Application,

		[Parameter(Mandatory = $true)]
		[string]
		$TenantId,

		[Parameter(Mandatory = $true)]
		$Config,

		[DateTimeOffset]
		$Now = [DateTimeOffset]::UtcNow
	)

	$thresholdDate = $Now.AddDays($Config.ThresholdDays)
	$graceDate = $Now.AddDays(-$Config.ExpiredGraceDays)
	$tags = @($Application.tags)

	$groups = @(
		@{ Type = 'Secret'; Credentials = @($Application.passwordCredentials | Where-Object { $_ }) }
		@{ Type = 'Certificate'; Credentials = @($Application.keyCredentials | Where-Object { $_ -and $_.type -eq 'AsymmetricX509Cert' -and $_.usage -eq 'Verify' }) }
		@{ Type = 'OtherKey'; Credentials = @($Application.keyCredentials | Where-Object { $_ -and -not ($_.type -eq 'AsymmetricX509Cert' -and $_.usage -eq 'Verify') }) }
	)

	foreach ($group in $groups) {
		if ($group.Credentials.Count -eq 0) { continue }

		$credentials = foreach ($credential in $group.Credentials) {
			$end = [DateTimeOffset]$credential.endDateTime
			$state = 'Valid'
			if ($end -le $Now) { $state = 'Expired' }
			elseif ($end -le $thresholdDate) { $state = 'Expiring' }

			[pscustomobject]@{
				KeyId         = $credential.keyId
				DisplayName   = $credential.displayName
				Hint          = $credential.hint
				CustomKeyId   = $credential.customKeyIdentifier
				StartDateTime = [DateTimeOffset]$credential.startDateTime
				EndDateTime   = $end
				DaysLeft      = [int][math]::Truncate(($end - $Now).TotalDays)
				State         = $state
			}
		}
		$credentials = @($credentials | Sort-Object EndDateTime -Descending)
		$newest = $credentials[0]

		$decision = 'Ok'
		$reason = "Newest credential is valid until $($newest.EndDateTime.ToString('yyyy-MM-dd'))."
		if ($group.Type -eq 'OtherKey') {
			$decision = 'Unsupported'
			$reason = 'Only AsymmetricX509Cert credentials with usage Verify are renewed.'
		}
		elseif ($newest.EndDateTime -le $thresholdDate) {
			if ($newest.EndDateTime -lt $graceDate) {
				$decision = 'Stale'
				$reason = "Expired $(-$newest.DaysLeft) days ago (grace period $($Config.ExpiredGraceDays) days). Not renewed - probably unused."
			}
			elseif ($Config.ExcludeTag -and $tags -contains $Config.ExcludeTag) {
				$decision = 'Excluded'
				$reason = "App has the tag '$($Config.ExcludeTag)'."
			}
			else {
				$decision = 'ApprovalRequired'
				if ($newest.State -eq 'Expired') { $reason = "Newest credential expired $(-$newest.DaysLeft) days ago." }
				else { $reason = "Newest credential expires in $($newest.DaysLeft) days." }
				$reason += ' Not renewed - waiting for approval.'
			}
		}

		[pscustomobject]@{
			TenantId          = $TenantId
			AppObjectId       = $Application.id
			AppId             = $Application.appId
			DisplayName       = $Application.displayName
			CredentialType    = $group.Type
			NewestEndDateTime = $newest.EndDateTime
			DaysLeft          = $newest.DaysLeft
			Decision          = $decision
			Reason            = $reason
			Credentials       = $credentials
		}
	}
}
