function Invoke-AppCredentialRenewalQueue {
	<#
	.SYNOPSIS
		Renews every credential an admin approved in the renewal state table.

	.DESCRIPTION
		Timer trigger (every 15 minutes). Reads the renewal state table and renews each row with
		RenewalState = Renewable (case-insensitive):

		1. Claim the row: RenewalState = InProgress, with If-Match on the ETag. If the row changed since
		   it was read (an admin edited it again), it is skipped.
		2. Renew the secret or certificate (Invoke-SrCredentialRenewal). Force = true in the row renews
		   apps with the exclude tag.
		3. Write the result: RenewalState = Renewed (RenewedOn, NewExpiresOn, VaultObject) or Failed
		   (RenewalMessage). Set Renewable again to retry a failed row.
		4. Send one mail with all renewals of this run.

		Runs that find nothing to do end after one table query.

	.EXAMPLE
		PS C:\> Invoke-AppCredentialRenewalQueue

		Processes all approved renewals.
	#>
	[CmdletBinding()]
	param ()

	$config = Get-SrConfig -Refresh
	$approved = @(Invoke-SrTableRequest -Operation Query -Filter "RenewalState ne 'None'" |
			Where-Object { "$($_.RenewalState)".Trim() -eq 'Renewable' })
	if ($approved.Count -eq 0) { return }
	Write-Host "Renewal queue: $($approved.Count) approved renewal(s)."

	$results = [System.Collections.Generic.List[object]]::new()
	foreach ($row in $approved) {
		$claimed = Invoke-SrTableRequest -Operation Merge -PartitionKey $row.PartitionKey -RowKey $row.RowKey -IfMatch $row.ETag -Properties @{
			RenewalState     = 'InProgress'
			RenewalStartedOn = [DateTimeOffset]::UtcNow.ToString('o')
			RenewalMessage   = ''
		}
		if (-not $claimed) {
			Write-Host "Row $($row.RowKey) changed since it was read - skipped."
			continue
		}

		$force = "$($row.Force)" -in 'true', '1', 'yes'
		$entry = Invoke-SrCredentialRenewal -TenantId $row.PartitionKey -AppId $row.AppId -CredentialType $row.CredentialType -Force:$force
		$entry | Add-Member -NotePropertyName RowKey -NotePropertyValue $row.RowKey -Force
		$entry | Add-Member -NotePropertyName RenewalState -NotePropertyValue $entry.Outcome -Force

		$properties = @{
			RenewalState   = $entry.Outcome
			RenewalMessage = "$($entry.Message)"
		}
		if ($entry.Outcome -eq 'Renewed') {
			$properties.RenewedOn = [DateTimeOffset]::UtcNow.ToString('o')
			$properties.NewExpiresOn = ([DateTimeOffset]$entry.NewEndDateTime).ToString('o')
			$properties.VaultObject = "$($entry.VaultObject)"
			# The next daily check would find this anyway - write it now so the table is right immediately
			$properties.CheckResult = 'Ok'
			$properties.ExpiresOn = $properties.NewExpiresOn
			$properties.Reason = "Renewed on approval. Newest credential is valid until $(([DateTimeOffset]$entry.NewEndDateTime).ToString('yyyy-MM-dd'))."
		}
		try { $null = Invoke-SrTableRequest -Operation Merge -PartitionKey $row.PartitionKey -RowKey $row.RowKey -Properties $properties }
		catch { Write-Warning "Writing the result of $($row.RowKey) to the state table failed: $_" }
		$results.Add($entry)
	}

	Send-SrNotification -Result $results.ToArray() -Kind Renewal -Config $config
	$failed = @($results | Where-Object Outcome -eq 'Failed').Count
	Write-Host "Renewal queue done: $($results.Count - $failed) renewed, $failed failed."
	if ($failed -gt 0) { throw "$failed approved renewal(s) failed. See RenewalMessage in the state table." }
}
