#Requires -Modules Az.Accounts
<#
.SYNOPSIS
	Calls the report endpoint of the Function App.

.DESCRIPTION
	Reads the default function key with your Az sign-in (POST .../host/default/listKeys) and calls
	GET /api/Get-AppCredentialReport. The endpoint is read-only.

.PARAMETER FunctionAppName
	Name of the Function App.

.PARAMETER ResourceGroupName
	Resource group of the Function App.

.PARAMETER State
	All, Expiring, Expired or Valid.

.PARAMETER ThresholdDays
	Override the threshold of the app settings for this report.

.PARAMETER SubscriptionId
	Subscription of the Function App, if it differs from the current Az context.

.EXAMPLE
	PS C:\> ./scripts/Invoke-SecretRotationReport.ps1 -FunctionAppName func-secrot-ab12c -ResourceGroupName rg-secrot-ab12c -State Expiring |
	>>   Format-Table DisplayName, CredentialType, EndDateTime, DaysLeft, Decision
#>
[CmdletBinding()]
param (
	[Parameter(Mandatory = $true)]
	[string]
	$FunctionAppName,

	[Parameter(Mandatory = $true)]
	[string]
	$ResourceGroupName,

	[ValidateSet('All', 'Expiring', 'Expired', 'Valid')]
	[string]
	$State = 'All',

	[int]
	$ThresholdDays,

	[string]
	$SubscriptionId
)

$ErrorActionPreference = 'Stop'
if (-not $SubscriptionId) { $SubscriptionId = (Get-AzContext).Subscription.Id }

$siteId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"
$keys = (Invoke-AzRestMethod -Method POST -Path "$siteId/host/default/listKeys?api-version=2024-04-01").Content | ConvertFrom-Json
$site = (Invoke-AzRestMethod -Method GET -Path "$siteId`?api-version=2024-04-01").Content | ConvertFrom-Json

$query = "State=$State"
if ($PSBoundParameters.ContainsKey('ThresholdDays')) { $query += "&ThresholdDays=$ThresholdDays" }

Invoke-RestMethod -Uri "https://$($site.properties.defaultHostName)/api/Get-AppCredentialReport?$query" -Headers @{
	'x-functions-key' = $keys.functionKeys.default
}
