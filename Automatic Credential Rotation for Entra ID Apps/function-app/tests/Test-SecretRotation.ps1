<#
.SYNOPSIS
	Offline test of the check, the renewal state table and the renewal queue against an in-memory fake
	of Graph, Key Vault and Table Storage.

.DESCRIPTION
	No Azure access needed. The script replaces Invoke-SrRestRequest, Invoke-SrTableRequest and
	Get-SrAccessToken inside the module with fakes and checks:
	- the daily check renews nothing, writes one row per app and type and sets expiring ones to Pending
	- only rows with RenewalState = Renewable are renewed, and the result is written back
	- a certificate PATCH keeps every existing certificate (with its key)
	- a secret is removed again when the Key Vault write fails
	- excluded apps need Force
	- the next check no longer reports what was renewed
	- the mails contain the approval command
	- token routing through the rotation app

.EXAMPLE
	PS C:\> ./tests/Test-SecretRotation.ps1
#>
[CmdletBinding()]
param ()

$ErrorActionPreference = 'Stop'
$moduleRoot = Join-Path (Split-Path $PSScriptRoot) 'SecretRotation'
Import-Module (Join-Path $moduleRoot 'SecretRotation.psd1') -Force

$env:SR_HOME_TENANT_ID = '11111111-1111-1111-1111-111111111111'
$env:SR_KEYVAULT_NAME = 'kv-test'
$env:SR_MAIL_SENDER = 'secretrotation@contoso.com'
$env:SR_MAIL_RECIPIENTS = 'admins@contoso.com'
$env:SR_ROTATION_APP_ID = '22222222-2222-2222-2222-222222222222'
$env:SR_STATE_STORAGE_ACCOUNT = 'sttest'

$failures = [System.Collections.Generic.List[string]]::new()
function Assert-That {
	param ([bool]$Condition, [string]$Message)
	if ($Condition) { Write-Host "  [PASS] $Message" -ForegroundColor Green }
	else { Write-Host "  [FAIL] $Message" -ForegroundColor Red; $failures.Add($Message) }
}

& (Get-Module SecretRotation) {
	# ---------- helpers to build fake data ----------
	function script:New-TestCertificate {
		param ([string]$Subject, [DateTimeOffset]$NotBefore, [DateTimeOffset]$NotAfter)
		$rsa = [System.Security.Cryptography.RSA]::Create(2048)
		$request = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new($Subject, $rsa, 'SHA256', [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
		$cert = $request.CreateSelfSigned($NotBefore, $NotAfter)
		[Convert]::ToBase64String($cert.Export('Cert'))
	}
	function script:New-Secret ([int]$DaysLeft, [string]$Name = 'manual') {
		$now = [DateTimeOffset]::UtcNow
		[pscustomobject]@{ keyId = [guid]::NewGuid().ToString(); displayName = $Name; hint = 'abc'; customKeyIdentifier = $null
			startDateTime = $now.AddDays(-300).UtcDateTime; endDateTime = $now.AddDays($DaysLeft).UtcDateTime }
	}
	function script:New-Cert ([int]$DaysLeft, [string]$Name = 'CN=manual') {
		$now = [DateTimeOffset]::UtcNow
		$start = $now.AddDays(-300); $end = $now.AddDays($DaysLeft)
		$cer = New-TestCertificate -Subject $Name -NotBefore $start -NotAfter $end
		[pscustomobject]@{ keyId = [guid]::NewGuid().ToString(); displayName = $Name; type = 'AsymmetricX509Cert'; usage = 'Verify'
			customKeyIdentifier = 'ABC'; key = $cer; startDateTime = $start.UtcDateTime; endDateTime = $end.UtcDateTime }
	}
	function script:New-App ([string]$Name, $Secrets = @(), $Certs = @(), $Tags = @()) {
		[pscustomobject]@{ id = [guid]::NewGuid().ToString(); appId = [guid]::NewGuid().ToString(); displayName = $Name
			tags = @($Tags); passwordCredentials = [System.Collections.Generic.List[object]]@($Secrets); keyCredentials = [System.Collections.Generic.List[object]]@($Certs) }
	}

	$symmetric = [pscustomobject]@{ keyId = [guid]::NewGuid().ToString(); displayName = 'legacy'; type = 'Symmetric'; usage = 'Sign'; customKeyIdentifier = $null
		key = 'AAAA'; startDateTime = [DateTime]::UtcNow.AddDays(-100); endDateTime = [DateTime]::UtcNow.AddDays(10) }

	$script:Fake = @{
		Apps        = @(
			New-App 'App-ExpiringSecret' -Secrets @(New-Secret 10)
			New-App 'App-RolledOver' -Secrets @((New-Secret 5), (New-Secret 200))
			New-App 'App-ExpiringCert' -Certs @((New-Cert 20 'CN=current'), (New-Cert -50 'CN=old'))
			New-App 'App-Excluded' -Secrets @(New-Secret 3) -Tags @('SecretRotation:Exclude')
			New-App 'App-Stale' -Secrets @(New-Secret -400)
			New-App 'App-ExpiredRecently' -Secrets @(New-Secret -2)
			New-App 'App-KeyVaultFails' -Secrets @(New-Secret 7)
			New-App 'App-OtherKey' -Certs @($symmetric)
		)
		Secrets     = @{}
		Certs       = @{}
		Patches     = [System.Collections.Generic.List[object]]::new()
		Removed     = [System.Collections.Generic.List[string]]::new()
		Disabled    = [System.Collections.Generic.List[string]]::new()
		Mails       = [System.Collections.Generic.List[object]]::new()
		AddPassword = 0
		CertCreates = 0
	}
	$script:Fake.FailingAppId = ($script:Fake.Apps | Where-Object displayName -eq 'App-KeyVaultFails').appId

	function script:Get-SrAccessToken { param ($Resource, $TenantId) "token-for-$Resource" }

	function script:Invoke-SrRestRequest {
		param ($Uri, $Method = 'GET', $Body, $TenantId, [switch]$All, [switch]$AllowNotFound, $MaxRetry)
		$u = [uri]$Uri
		$path = $u.AbsolutePath
		if ($null -ne $Body -and $Body -isnot [string]) { $Body = $Body | ConvertTo-Json -Depth 20 | ConvertFrom-Json }

		# ---------------- Graph ----------------
		if ($u.Host -eq 'graph.microsoft.com') {
			if ($Method -eq 'GET' -and $path -eq '/v1.0/applications') {
				$query = [uri]::UnescapeDataString($u.Query)
				$apps = $script:Fake.Apps
				if ($query -match "appId eq '([^']+)'") { $wanted = $Matches[1]; $apps = @($apps | Where-Object appId -eq $wanted) }
				return @($apps | ForEach-Object {
						$app = $_
						[pscustomobject]@{ id = $app.id; appId = $app.appId; displayName = $app.displayName; tags = $app.tags
							passwordCredentials = @($app.passwordCredentials)
							keyCredentials = @($app.keyCredentials | ForEach-Object { $c = $_.PSObject.Copy(); $c.key = $null; $c })
						}
					})
			}
			if ($path -match '^/v1\.0/applications/([^/]+)(/(\w+))?$') {
				$app = $script:Fake.Apps | Where-Object id -eq $Matches[1]
				$action = $Matches[3]
				if ($Method -eq 'GET') { return [pscustomobject]@{ keyCredentials = @($app.keyCredentials) } }
				if ($action -eq 'addPassword') {
					$script:Fake.AddPassword++
					$new = [pscustomobject]@{ keyId = [guid]::NewGuid().ToString(); displayName = $Body.passwordCredential.displayName; hint = 'Xyz'
						secretText = 'Xyz-super-secret'; customKeyIdentifier = $null
						startDateTime = ([DateTimeOffset]$Body.passwordCredential.startDateTime).UtcDateTime
						endDateTime = ([DateTimeOffset]$Body.passwordCredential.endDateTime).UtcDateTime }
					$stored = $new.PSObject.Copy(); $stored.secretText = $null
					$app.passwordCredentials.Add($stored)
					return $new
				}
				if ($action -eq 'removePassword') {
					$script:Fake.Removed.Add($Body.keyId)
					$null = $app.passwordCredentials.RemoveAll([Predicate[object]] { param ($c) $c.keyId -eq $Body.keyId })
					return
				}
				if ($Method -eq 'PATCH') {
					$script:Fake.Patches.Add([pscustomobject]@{ AppId = $app.appId; KeyCredentials = @($Body.keyCredentials) })
					foreach ($kc in $Body.keyCredentials) { if (-not $kc.key) { throw 'PATCH without key would delete a credential' } }
					$app.keyCredentials = [System.Collections.Generic.List[object]]@($Body.keyCredentials | ForEach-Object {
							$kid = $_.keyId; if (-not $kid) { $kid = [guid]::NewGuid().ToString() }
							[pscustomobject]@{ keyId = $kid; displayName = $_.displayName; type = $_.type; usage = $_.usage; key = $_.key; customKeyIdentifier = $_.customKeyIdentifier
								startDateTime = ([DateTimeOffset]$_.startDateTime).UtcDateTime; endDateTime = ([DateTimeOffset]$_.endDateTime).UtcDateTime }
						})
					return
				}
			}
			if ($Method -eq 'POST' -and $path -like '/v1.0/users/*/sendMail') { $script:Fake.Mails.Add($Body); return }
			throw "Fake Graph: unhandled $Method $Uri"
		}

		# ---------------- Key Vault ----------------
		if ($u.Host -eq 'kv-test.vault.azure.net') {
			if ($path -match '^/secrets/([^/]+)$') {
				$name = $Matches[1]
				if ($Method -eq 'PUT') {
					if ($name -like "*$($script:Fake.FailingAppId)*") { throw 'PUT kv-test.vault.azure.net/secrets failed: 403 Forbidden (simulated)' }
					$script:Fake.Secrets[$name] = $Body.value
					return [pscustomobject]@{ id = "https://kv-test.vault.azure.net/secrets/$name/v1" }
				}
				if ($script:Fake.Secrets.ContainsKey($name)) { return [pscustomobject]@{ id = $name; value = $script:Fake.Secrets[$name] } }
				if ($AllowNotFound) { return $null }
				throw "404 $name"
			}
			if ($path -match '^/certificates/([^/]+)/create$') {
				$name = $Matches[1]
				$script:Fake.CertCreates++
				$months = $Body.policy.x509_props.validity_months
				$now = [DateTimeOffset]::UtcNow
				$script:Fake.Certs[$name] = [pscustomobject]@{
					id  = "https://kv-test.vault.azure.net/certificates/$name/$([guid]::NewGuid().ToString('N'))"
					cer = New-TestCertificate -Subject $Body.policy.x509_props.subject -NotBefore $now.AddMinutes(-5) -NotAfter $now.AddMonths($months)
				}
				return [pscustomobject]@{ status = 'inProgress' }
			}
			if ($path -match '^/certificates/([^/]+)/pending$') { return [pscustomobject]@{ status = 'completed' } }
			if ($Method -eq 'GET' -and $path -match '^/certificates/([^/]+)$') { return $script:Fake.Certs[$Matches[1]] }
			if ($Method -eq 'PATCH' -and $path -match '^/certificates/') { $script:Fake.Disabled.Add($Uri); return }
			throw "Fake Key Vault: unhandled $Method $Uri"
		}
		throw "Fake: unexpected host $($u.Host)"
	}

	# ---------------- Table Storage ----------------
	$script:Fake.Table = [ordered]@{}
	$script:Fake.EtagCounter = 0
	$script:Fake.BumpBeforeMerge = $null
	function script:Invoke-SrTableRequest {
		param ($Operation, $Filter, $PartitionKey, $RowKey, [hashtable]$Properties = @{}, $IfMatch)
		$t = $script:Fake.Table
		if ($Operation -eq 'Query') {
			$rows = foreach ($key in @($t.Keys)) { $t[$key] }
			if ($Filter -match "^PartitionKey eq '([^']+)'$") { $pk = $Matches[1]; $rows = $rows | Where-Object PartitionKey -eq $pk }
			elseif ($Filter -eq "RenewalState ne 'None'") { $rows = $rows | Where-Object { $_.RenewalState -cne 'None' } }
			elseif ($Filter) { throw "Fake table: unsupported filter $Filter" }
			return @($rows | ForEach-Object { [pscustomobject]$_.Clone() })
		}
		$key = "$PartitionKey|$RowKey"
		if ($Operation -eq 'Delete') { $t.Remove($key); return }
		if ($script:Fake.BumpBeforeMerge -eq $RowKey -and $t.Contains($key)) { $t[$key].ETag = "etag-$(++$script:Fake.EtagCounter)"; $script:Fake.BumpBeforeMerge = $null }
		if ($IfMatch -and $t.Contains($key) -and $t[$key].ETag -ne $IfMatch) { return $false }
		if (-not $t.Contains($key)) { $t[$key] = @{ PartitionKey = $PartitionKey; RowKey = $RowKey } }
		foreach ($p in $Properties.Keys) { $t[$key][$p] = $Properties[$p] }
		$t[$key].ETag = "etag-$(++$script:Fake.EtagCounter)"
		$true
	}

	# The fake creates the pending certificate instantly - don't wait
	function script:Start-Sleep { param ($Seconds) }
}

function Get-Fake { & (Get-Module SecretRotation) { $script:Fake } }
function Get-AppId ([string]$Name) { ((Get-Fake).Apps | Where-Object displayName -eq $Name).appId }
function Get-Row ([string]$Name, [string]$Type = 'Secret') { (Get-Fake).Table["$($env:SR_HOME_TENANT_ID)|$(Get-AppId $Name)_$Type"] }
function Set-Row ([string]$Name, [string]$Type = 'Secret', [hashtable]$Properties) {
	$row = Get-Row $Name $Type
	foreach ($k in $Properties.Keys) { $row[$k] = $Properties[$k] }
	$row.ETag = "etag-admin-$([guid]::NewGuid())"   # an edit in the portal changes the ETag
}

# Capture what goes into the mails by wrapping Send-SrNotification (once)
& (Get-Module SecretRotation) {
	$script:OriginalSend = ${function:Send-SrNotification}
	function script:Send-SrNotification {
		param ($Result, $Kind, $Config)
		$script:LastResult = $Result
		& $script:OriginalSend -Result $Result -Kind $Kind -Config $Config
	}
}
function Invoke-Check {
	& (Get-Module SecretRotation) {
		$script:SrConfig = $null; $script:LastResult = $null
		try { Invoke-AppCredentialCheck 6>$null | Out-Null; $err = $null } catch { $err = $_ }
		[pscustomobject]@{ Results = $script:LastResult; Error = $err }
	}
}
function Invoke-Queue {
	& (Get-Module SecretRotation) {
		$script:SrConfig = $null; $script:LastResult = $null
		try { Invoke-AppCredentialRenewalQueue 6>$null | Out-Null; $err = $null } catch { $err = $_ }
		[pscustomobject]@{ Results = $script:LastResult; Error = $err }
	}
}

Write-Host "`nDaily check - renews nothing, fills the state table" -ForegroundColor Cyan
$check1 = Invoke-Check
$fake = Get-Fake
$byApp = @{}; foreach ($r in $check1.Results) { $byApp["$($r.DisplayName)|$($r.Outcome)"] = $r }

Assert-That ($null -eq $check1.Error) "Check runs without error $($check1.Error)"
Assert-That ($fake.AddPassword -eq 0 -and $fake.CertCreates -eq 0 -and $fake.Patches.Count -eq 0) 'Check creates no secret, no certificate and changes no app'
Assert-That ($fake.Table.Count -eq 8) "One row per app and credential type ($($fake.Table.Count) rows)"
Assert-That ((Get-Row 'App-ExpiringSecret').RenewalState -eq 'Pending' -and (Get-Row 'App-ExpiringSecret').CheckResult -eq 'ApprovalRequired') 'Expiring secret: CheckResult ApprovalRequired, RenewalState Pending'
Assert-That ((Get-Row 'App-ExpiringCert' 'Certificate').RenewalState -eq 'Pending') 'Expiring certificate: RenewalState Pending'
Assert-That ((Get-Row 'App-RolledOver').RenewalState -eq 'None' -and (Get-Row 'App-RolledOver').CheckResult -eq 'Ok') 'App with a newer valid secret: RenewalState None'
Assert-That ((Get-Row 'App-Excluded').CheckResult -eq 'Excluded' -and (Get-Row 'App-Excluded').RenewalState -eq 'None') 'Excluded app: reported, not Pending'
Assert-That ((Get-Row 'App-ExpiringSecret').Reason -like '*waiting for approval*') 'The row says the credential waits for approval'
Assert-That ($byApp.ContainsKey('App-ExpiringSecret|ApprovalRequired') -and $byApp.ContainsKey('App-Stale|Stale') -and $byApp.ContainsKey('App-OtherKey|Unsupported')) 'Mail entries: approval, stale, unsupported'

$certApp = $fake.Apps | Where-Object displayName -eq 'App-ExpiringCert'
$currentThumb = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([Convert]::FromBase64String(($certApp.keyCredentials | Where-Object displayName -eq 'CN=current').key)).Thumbprint.ToLowerInvariant()
Assert-That ($fake.Secrets.ContainsKey("app-$($certApp.appId)-pub-$currentThumb")) 'Public part of the existing certificate is backed up'

Assert-That ($fake.Mails.Count -eq 1) 'One report mail is sent'
$mail1 = $fake.Mails[0].message.body.content
Assert-That ($mail1 -like "*RowKey $(Get-AppId 'App-ExpiringSecret')_Secret*" -and $mail1 -like '*Set-SecretRotationState.ps1*-State Renewable*') 'Mail names the table row and the command to approve'

Write-Host "`nRenewal queue - nothing approved" -ForegroundColor Cyan
$queue0 = Invoke-Queue
Assert-That ($null -eq $queue0.Error -and $fake.AddPassword -eq 0 -and $fake.Mails.Count -eq 1) 'Queue without Renewable rows does nothing and sends no mail'

Write-Host "`nRenewal queue - approved rows" -ForegroundColor Cyan
Set-Row 'App-ExpiringSecret' -Properties @{ RenewalState = 'renewable' }          # lower case on purpose
Set-Row 'App-ExpiringCert' 'Certificate' -Properties @{ RenewalState = 'Renewable' }
Set-Row 'App-KeyVaultFails' -Properties @{ RenewalState = 'Renewable' }
Set-Row 'App-Excluded' -Properties @{ RenewalState = 'Renewable' }
Set-Row 'App-RolledOver' -Properties @{ RenewalState = 'Renewable' }              # not expiring - admin wants it anyway
$queue1 = Invoke-Queue

Assert-That ((Get-Row 'App-ExpiringSecret').RenewalState -eq 'Renewed' -and (Get-Row 'App-ExpiringSecret').NewExpiresOn) 'Approved secret is renewed, row shows Renewed + NewExpiresOn'
Assert-That ((Get-Row 'App-ExpiringSecret').CheckResult -eq 'Ok') 'Row is Ok right after the renewal'
Assert-That ($fake.Secrets["app-$(Get-AppId 'App-ExpiringSecret')-secret"] -eq 'Xyz-super-secret') 'New secret value is in Key Vault'
Assert-That (-not ($fake.Table.Values | Where-Object { ($_.Values -join ' ') -like '*super-secret*' })) 'The secret value never lands in the table'
$patch = $fake.Patches | Where-Object AppId -eq $certApp.appId
Assert-That ((Get-Row 'App-ExpiringCert' 'Certificate').RenewalState -eq 'Renewed' -and @($patch.KeyCredentials).Count -eq 3) 'Approved certificate is renewed, PATCH keeps the 2 existing certificates'
Assert-That (@($patch.KeyCredentials | Where-Object { -not $_.key }).Count -eq 0) 'Every key credential in the PATCH has its key'
$failingApp = $fake.Apps | Where-Object displayName -eq 'App-KeyVaultFails'
Assert-That ((Get-Row 'App-KeyVaultFails').RenewalState -eq 'Failed' -and (Get-Row 'App-KeyVaultFails').RenewalMessage -like '*Key Vault*') 'Key Vault failure: row Failed with the reason'
Assert-That ($fake.Removed.Count -eq 1 -and @($failingApp.passwordCredentials).Count -eq 1) 'New secret is removed again after the Key Vault failure'
Assert-That ((Get-Row 'App-Excluded').RenewalState -eq 'Failed' -and (Get-Row 'App-Excluded').RenewalMessage -like '*Force*') 'Excluded app without Force: Failed, message names Force'
Assert-That ((Get-Row 'App-RolledOver').RenewalState -eq 'Renewed') 'A credential that is not expiring yet is renewed when approved'
Assert-That ("$($queue1.Error)" -like '*2 approved renewal(s) failed*') 'Queue run reports the failures to monitoring'
Assert-That ($fake.Mails.Count -eq 2 -and $fake.Mails[1].message.subject -like '*3 renewed, 2 failed*') "One mail for the queue run ($($fake.Mails[1].message.subject))"

$addBefore = $fake.AddPassword
Set-Row 'App-Excluded' -Properties @{ RenewalState = 'Renewable'; Force = $true }
$null = Invoke-Queue
Assert-That ((Get-Row 'App-Excluded').RenewalState -eq 'Renewed' -and $fake.AddPassword -eq $addBefore + 1) 'Excluded app with Force = true is renewed'

Write-Host "`nConcurrency" -ForegroundColor Cyan
$addBefore = $fake.AddPassword
Set-Row 'App-ExpiredRecently' -Properties @{ RenewalState = 'Renewable' }
& (Get-Module SecretRotation) { $script:Fake.BumpBeforeMerge = $args[0] } "$(Get-AppId 'App-ExpiredRecently')_Secret"
$null = Invoke-Queue
Assert-That ($fake.AddPassword -eq $addBefore -and (Get-Row 'App-ExpiredRecently').RenewalState -eq 'Renewable') 'Row edited between read and claim is skipped (If-Match)'
Set-Row 'App-ExpiredRecently' -Properties @{ RenewalState = 'Declined' }

Write-Host "`nNext daily check" -ForegroundColor Cyan
Set-Row 'App-Stale' -Properties @{ RenewalState = 'Renewabel' }                    # typo
Set-Row 'App-OtherKey' 'OtherKey' -Properties @{ RenewalState = 'InProgress'; RenewalStartedOn = [DateTimeOffset]::UtcNow.AddHours(-2).ToString('o') }
$check2 = Invoke-Check
$outcomes = @{}; foreach ($r in $check2.Results) { $outcomes[$r.DisplayName] = $r.Outcome }
Assert-That (-not $outcomes.ContainsKey('App-ExpiringSecret') -and -not $outcomes.ContainsKey('App-ExpiringCert')) 'Renewed apps are no longer in the mail'
Assert-That ((Get-Row 'App-ExpiringSecret').RenewalState -eq 'Renewed') 'Renewed stays Renewed while the credential is Ok'
Assert-That ($outcomes['App-KeyVaultFails'] -eq 'Failed' -and (Get-Row 'App-KeyVaultFails').RenewalState -eq 'Failed') 'Failed renewal stays Failed and is in the mail'
Assert-That (-not $outcomes.ContainsKey('App-ExpiredRecently') -and (Get-Row 'App-ExpiredRecently').RenewalState -eq 'Declined') 'Declined: no reminder, state kept'
Assert-That ($outcomes['App-Stale'] -eq 'InvalidState' -and (Get-Row 'App-Stale').RenewalState -eq 'Renewabel') 'Unknown value: reported as InvalidState, not changed'
Assert-That ((Get-Row 'App-OtherKey' 'OtherKey').RenewalState -eq 'Failed' -and (Get-Row 'App-OtherKey' 'OtherKey').RenewalMessage -like '*interrupted*') 'InProgress for 2 hours becomes Failed (interrupted)'

Write-Host "`nRemoved credentials" -ForegroundColor Cyan
$goneId = Get-AppId 'App-RolledOver'
Set-Row 'App-Excluded' -Properties @{ RenewalState = 'Renewable' }
& (Get-Module SecretRotation) { $script:Fake.Apps = @($script:Fake.Apps | Where-Object displayName -notin 'App-RolledOver', 'App-Excluded') }
$excludedKey = ($fake.Table.Keys | Where-Object { $_ -like '*_Secret' -and $fake.Table[$_].DisplayName -eq 'App-Excluded' })
$null = Invoke-Check
Assert-That (-not ($fake.Table.Keys | Where-Object { $_ -like "*$goneId*" })) 'Row of a deleted app is removed'
Assert-That ($fake.Table.Contains($excludedKey)) 'A Renewable row is kept even if the app is gone (the queue reports the failure)'

Write-Host "`nRenewalState rules" -ForegroundColor Cyan
$rules = & (Get-Module SecretRotation) {
	@(
		(Get-SrNextRenewalState -CurrentState $null -CheckResult 'ApprovalRequired').State
		(Get-SrNextRenewalState -CurrentState 'Renewed' -CheckResult 'ApprovalRequired').State
		(Get-SrNextRenewalState -CurrentState 'Renewable' -CheckResult 'Ok').State
		(Get-SrNextRenewalState -CurrentState 'Pending' -CheckResult 'Ok').State
		(Get-SrNextRenewalState -CurrentState 'InProgress' -CheckResult 'Ok' -RenewalStartedOn ([DateTimeOffset]::UtcNow.AddMinutes(-5))).State
		(Get-SrNextRenewalState -CurrentState 'DECLINED' -CheckResult 'ApprovalRequired').State
	)
}
Assert-That ($rules[0] -eq 'Pending') 'New expiring row -> Pending'
Assert-That ($rules[1] -eq 'Pending') 'Renewed credential expiring again -> Pending'
Assert-That ($null -eq $rules[2]) 'Renewable is never changed by the check'
Assert-That ($rules[3] -eq 'None') 'Pending but renewed elsewhere -> None'
Assert-That ($null -eq $rules[4]) 'InProgress for 5 minutes is left alone'
Assert-That ($null -eq $rules[5]) 'Declined (any case) is kept while it expires'

Write-Host "`nReport endpoint and guards" -ForegroundColor Cyan
$report = & (Get-Module SecretRotation) { $script:SrConfig = $null; Get-AppCredentialReport -State Expiring -ThresholdDays '30' }
Assert-That (@($report | Where-Object DisplayName -eq 'App-Stale' | Where-Object State -eq 'Expired').Count -eq 1) 'Report lists the expired secret of App-Stale'
Assert-That (@($report | Where-Object { $_.DisplayName -eq 'App-KeyVaultFails' -and $_.Decision -eq 'ApprovalRequired' -and $_.Reason -like '*waiting for approval*' -and $_.RenewalState -eq 'Failed' }).Count -ge 1) 'HTTP report shows the decision and the RenewalState from the table'
Assert-That (@($report | Where-Object State -eq 'Valid').Count -eq 0) 'Report filter Expiring hides valid credentials'
$refused = $false
Import-Module (Join-Path $moduleRoot 'SecretRotation.psd1') -Force
try { & (Get-Module SecretRotation) { Invoke-SrRestRequest -Uri 'https://attacker.example.com/v1.0/me' } } catch { $refused = "$_" -like 'Refusing to send a token*' }
Assert-That $refused 'A token is never sent to a host other than Graph or Key Vault'

Write-Host "`nTable REST calls" -ForegroundColor Cyan
Import-Module (Join-Path $moduleRoot 'SecretRotation.psd1') -Force
$tableCalls = & (Get-Module SecretRotation) {
	$script:SrConfig = $null
	$script:TCalls = [System.Collections.Generic.List[object]]::new()
	function script:Get-SrAccessToken { param ($Resource, $TenantId) "token-for-$Resource" }
	function script:Invoke-RestMethod {
		param ($Method, $CustomMethod, $Uri, $Headers, $Body, $ContentType, [switch]$SkipHttpErrorCheck, $StatusCodeVariable, $ResponseHeadersVariable, $ErrorAction)
		$script:TCalls.Add([pscustomobject]@{ Method = "$Method$CustomMethod"; Uri = "$Uri"; Headers = $Headers.Clone(); Body = $(if ($Body) { [System.Text.Encoding]::UTF8.GetString($Body) }) })
		if ($StatusCodeVariable) { Set-Variable -Name $StatusCodeVariable -Value $(if ($Headers['If-Match'] -eq 'stale') { 412 } else { 204 }) -Scope 1 }
		if ($ResponseHeadersVariable) { Set-Variable -Name $ResponseHeadersVariable -Value @{} -Scope 1 }
		if ("$Method" -eq 'Get') { return [pscustomobject]@{ value = @([pscustomobject]@{ PartitionKey = 't'; RowKey = 'r'; 'odata.etag' = 'W/"1"' }) } }
	}
	$rows = Invoke-SrTableRequest -Operation Query -Filter "PartitionKey eq 't'"
	$ok = Invoke-SrTableRequest -Operation Merge -PartitionKey 't' -RowKey 'r' -Properties @{ RenewalState = 'InProgress' } -IfMatch 'W/"1"'
	$stale = Invoke-SrTableRequest -Operation Merge -PartitionKey 't' -RowKey 'r' -Properties @{ RenewalState = 'InProgress' } -IfMatch 'stale'
	[pscustomobject]@{ Calls = $script:TCalls.ToArray(); Rows = $rows; Ok = $ok; Stale = $stale }
}
$q = $tableCalls.Calls[0]; $m = $tableCalls.Calls[1]
Assert-That ($q.Uri -like "https://sttest.table.core.windows.net/CredentialRenewals()?`$filter=PartitionKey%20eq%20%27t%27*") "Query goes to the configured account and table ($($q.Uri))"
Assert-That ($q.Headers.Authorization -eq 'Bearer token-for-https://storage.azure.com/' -and $q.Headers['x-ms-version'] -eq '2020-12-06') 'Entra ID token for storage + x-ms-version'
Assert-That ($tableCalls.Rows[0].ETag -eq 'W/"1"') 'Query returns the ETag of each row'
Assert-That ($m.Method -eq 'MERGE' -and $m.Uri -like "*CredentialRenewals(PartitionKey='t',RowKey='r')" -and $m.Headers['If-Match'] -eq 'W/"1"') 'Merge uses MERGE on the entity URL with If-Match'
Assert-That ($tableCalls.Ok -eq $true -and $tableCalls.Stale -eq $false) 'HTTP 412 (row changed) returns $false instead of throwing'

Write-Host "`nToken routing" -ForegroundColor Cyan
$customerTenant = '33333333-3333-3333-3333-333333333333'
Import-Module (Join-Path $moduleRoot 'SecretRotation.psd1') -Force
$routing = & (Get-Module SecretRotation) {
	param ($CustomerTenant)
	$script:SrConfig = $null
	$script:Calls = [System.Collections.Generic.List[string]]::new()
	function script:Get-SrManagedIdentityToken { param ($Resource) $script:Calls.Add("MI|$Resource"); [pscustomobject]@{ Token = "mi-$Resource"; ExpiresOn = [DateTimeOffset]::UtcNow.AddHours(1) } }
	function script:Invoke-RestMethod { param ($Method, $Uri, $Body, $ContentType, $ErrorAction)
		$script:Calls.Add("EXCHANGE|$Uri|$($Body.client_id)|$($Body.client_assertion)|$($Body.scope)")
		[pscustomobject]@{ access_token = 'app-token'; expires_in = 3599 } }
	$env:IDENTITY_ENDPOINT = 'http://localhost/msi'; $env:IDENTITY_HEADER = 'x'
	$null = Get-SrAccessToken -Resource 'https://graph.microsoft.com'
	$null = Get-SrAccessToken -Resource 'https://graph.microsoft.com' -TenantId $CustomerTenant
	$null = Get-SrAccessToken -Resource 'https://vault.azure.net'
	$kvCustomer = $false
	try { $null = Get-SrAccessToken -Resource 'https://vault.azure.net' -TenantId $CustomerTenant } catch { $kvCustomer = "$_" -like 'Only Microsoft Graph*' }
	Remove-Item Env:IDENTITY_ENDPOINT, Env:IDENTITY_HEADER
	[pscustomobject]@{ Calls = $script:Calls.ToArray(); KvCustomerRefused = $kvCustomer }
} $customerTenant
$exchanges = @($routing.Calls | Where-Object { $_ -like 'EXCHANGE|*' })
Assert-That ($exchanges.Count -eq 2) 'Graph tokens for home and customer tenant both come from the token exchange'
Assert-That ($exchanges[0] -like "EXCHANGE|https://login.microsoftonline.com/$($env:SR_HOME_TENANT_ID)/oauth2/v2.0/token|$($env:SR_ROTATION_APP_ID)|mi-api://AzureADTokenExchange|https://graph.microsoft.com/.default") 'Home tenant: rotation app ID + managed identity assertion'
Assert-That ($exchanges[1] -like "EXCHANGE|https://login.microsoftonline.com/$customerTenant/*") 'Customer tenant: exchange against the customer tenant endpoint'
Assert-That (@($routing.Calls | Where-Object { $_ -eq 'MI|https://graph.microsoft.com' }).Count -eq 0) 'The managed identity never requests a Graph token itself'
Assert-That (@($routing.Calls | Where-Object { $_ -eq 'MI|https://vault.azure.net' }).Count -eq 1) 'Key Vault token comes directly from the managed identity'
Assert-That $routing.KvCustomerRefused 'Non-Graph tokens for another tenant are refused'

$missingApp = $false
$saved = $env:SR_ROTATION_APP_ID; $env:SR_ROTATION_APP_ID = ''
try { & (Get-Module SecretRotation) { $null = Get-SrConfig -Refresh } } catch { $missingApp = "$_" -like '*SR_ROTATION_APP_ID*' }
$env:SR_ROTATION_APP_ID = $saved
Assert-That $missingApp 'Configuration without SR_ROTATION_APP_ID is rejected'

Write-Host ''
if ($failures.Count -gt 0) { throw "$($failures.Count) test(s) failed." }
Write-Host 'All tests passed.' -ForegroundColor Green
