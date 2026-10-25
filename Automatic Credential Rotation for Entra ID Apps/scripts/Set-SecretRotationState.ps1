#Requires -Modules Az.Accounts
<#
.SYNOPSIS
	Sets the RenewalState of one credential in the renewal state table - e.g. to approve a renewal.

.DESCRIPTION
	The same as editing the row in the Azure portal (storage account -> Storage browser -> Tables) or in
	Azure Storage Explorer, just from PowerShell:

	  Renewable  approve - the renewal queue renews it within 15 minutes
	  Declined   don't renew, no more reminders in the daily mail
	  None       reset

	Uses your Az sign-in with Entra ID auth (no account key). You need 'Storage Table Data Contributor'
	on the table (Terraform: admin_principal_ids). Who changed what is in the storage account's logs.

.PARAMETER StorageAccountName
	Storage account of the state table (Terraform output state_storage_account).

.PARAMETER TableName
	Name of the state table.

.PARAMETER TenantId
	Tenant of the app (PartitionKey).

.PARAMETER AppId
	Application (client) ID of the app.

.PARAMETER CredentialType
	Secret or Certificate.

.PARAMETER State
	Renewable, Declined or None.

.PARAMETER Force
	Also renew if the app has the exclude tag (writes Force = true into the row).

.PARAMETER Comment
	Free text for the row, e.g. who approved and why.

.EXAMPLE
	PS C:\> ./scripts/Set-SecretRotationState.ps1 -StorageAccountName stsecrotab12c -TenantId $tenantId -AppId $appId -CredentialType Secret -State Renewable -Comment 'Approved by CH, change 4711'
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', 'CredentialType', Justification = 'The kind of credential (Secret/Certificate), not a credential')]
[CmdletBinding(SupportsShouldProcess)]
param (
	[Parameter(Mandatory = $true)]
	[string]
	$StorageAccountName,

	[string]
	$TableName = 'CredentialRenewals',

	[Parameter(Mandatory = $true)]
	[guid]
	$TenantId,

	[Parameter(Mandatory = $true)]
	[guid]
	$AppId,

	[Parameter(Mandatory = $true)]
	[ValidateSet('Secret', 'Certificate')]
	[string]
	$CredentialType,

	[Parameter(Mandatory = $true)]
	[ValidateSet('Renewable', 'Declined', 'None')]
	[string]
	$State,

	[switch]
	$Force,

	[string]
	$Comment
)

$ErrorActionPreference = 'Stop'
$token = (Get-AzAccessToken -ResourceUrl 'https://storage.azure.com/').Token
if ($token -is [securestring]) { $token = [System.Net.NetworkCredential]::new('', $token).Password }

$rowKey = '{0}_{1}' -f $AppId, $CredentialType
$uri = "https://$StorageAccountName.table.core.windows.net/$TableName(PartitionKey='$TenantId',RowKey='$rowKey')"
$headers = @{
	Authorization  = "Bearer $token"
	'x-ms-version' = '2020-12-06'
	'x-ms-date'    = [DateTime]::UtcNow.ToString('R')
	Accept         = 'application/json;odata=nometadata'
}

# The row must exist - the daily check creates it. A typo in the app ID shouldn't create a new row.
try { $row = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers }
catch { throw "No row for app $AppId ($CredentialType) in tenant $TenantId. Has the daily check seen this credential?" }

$properties = @{ RenewalState = $State; Force = [bool]$Force; LastChanged = [DateTimeOffset]::UtcNow.ToString('o') }
if ($Comment) { $properties.Comment = $Comment }

if ($PSCmdlet.ShouldProcess("$($row.DisplayName) ($CredentialType, expires $($row.ExpiresOn))", "RenewalState $($row.RenewalState) -> $State")) {
	$headers['If-Match'] = '*'
	$null = Invoke-RestMethod -CustomMethod MERGE -Uri $uri -Headers $headers -Body ($properties | ConvertTo-Json) -ContentType 'application/json'
	Write-Host "$($row.DisplayName) ($CredentialType): RenewalState = $State"
}
