<#
.SYNOPSIS
	Calls one of the Azure Update Manager Function App endpoints.

.DESCRIPTION
	Small client for testing. Gets the default function key via the ARM REST API
	(POST .../host/default/listKeys, called with Invoke-AzRestMethod), then calls the endpoint
	with the x-functions-key header.

	Sign in first with Connect-AzAccount. The signed-in identity needs the right to list the
	keys of the Function App (Microsoft.Web/sites/host/listkeys/action, e.g. Contributor).

	Endpoints and their parameters (see the functions in function-app/UpdateManagerAutomation/functions/httpTrigger):

	Get-UpdateManagerMachine            TagName, TagValue, OsType, SubscriptionId
	Get-UpdateMaintenanceConfiguration  Name, MaintenanceScope, SubscriptionId
	Start-UpdateAssessment              TagName, TagValue, SubscriptionId
	Start-OneTimeUpdate                 TagName, TagValue, MachineName, ExclusionScope, RebootSetting, MaximumDuration,
	                                    Classification, LinuxClassification, AdditionalExcludedKb, SubscriptionId
	New-UpdateMaintenanceConfiguration  Name, StartDateTime, RecurEvery, Duration, TimeZone, ExpirationDateTime,
	                                    RebootSetting, Classification, LinuxClassification, ExcludedKb,
	                                    ExclusionScope, TagName, TagValue, ResourceGroupName, SubscriptionId,
	                                    DynamicScopeSubscriptionId, Location

.PARAMETER FunctionAppName
	Name of the Function App (Terraform output 'function_app_name').

.PARAMETER ResourceGroupName
	Resource group of the Function App (Terraform output 'resource_group_name').

.PARAMETER Endpoint
	The function to call.

.PARAMETER Parameters
	Hashtable with the parameters of the function. Sent as JSON body.

.PARAMETER SubscriptionId
	Subscription of the Function App. Defaults to the subscription of the current Az context.

.EXAMPLE
	PS C:\> Connect-AzAccount
	PS C:\> $call = @{
		FunctionAppName   = 'func-aum-x1y2z'
		ResourceGroupName = 'rg-aum-automation'
		Endpoint          = 'Get-UpdateManagerMachine'
	}
	PS C:\> ./Invoke-UpdateManagerFunction.ps1 @call

	Lists all Azure VMs and Arc-enabled servers Azure Update Manager can see, with their latest assessment summary.

.EXAMPLE
	PS C:\> $call = @{
		FunctionAppName   = 'func-aum-x1y2z'
		ResourceGroupName = 'rg-aum-automation'
		Endpoint          = 'Get-UpdateManagerMachine'
		Parameters        = @{
			TagName  = 'UpdateGroup'
			TagValue = 'Wave1'
			OsType   = 'Windows'
		}
	}
	PS C:\> $format = @{
		Property = 'Name', 'State', 'LastAssessment', 'CriticalUpdates', 'SecurityUpdates', 'RebootPending'
	}
	PS C:\> ./Invoke-UpdateManagerFunction.ps1 @call | Format-Table @format

	Shows the pending updates of all Windows machines tagged UpdateGroup=Wave1.

.EXAMPLE
	PS C:\> $call = @{
		FunctionAppName   = 'func-aum-x1y2z'
		ResourceGroupName = 'rg-aum-automation'
		Endpoint          = 'Start-UpdateAssessment'
		Parameters        = @{
			TagName  = 'UpdateGroup'
			TagValue = 'Wave1'
		}
	}
	PS C:\> ./Invoke-UpdateManagerFunction.ps1 @call

	"Check for updates": starts an on-demand patch assessment on all machines tagged UpdateGroup=Wave1.
	Afterwards, call Get-UpdateManagerMachine again to read the fresh results.

.EXAMPLE
	PS C:\> $call = @{
		FunctionAppName   = 'func-aum-x1y2z'
		ResourceGroupName = 'rg-aum-automation'
		Endpoint          = 'Start-OneTimeUpdate'
		Parameters        = @{
			TagName  = 'UpdateGroup'
			TagValue = 'Wave1'
		}
	}
	PS C:\> ./Invoke-UpdateManagerFunction.ps1 @call

	Installs Critical + Security updates on all machines tagged UpdateGroup=Wave1, minus the KBs from the
	exclusion table ('Global' + 'Wave1'). Reboots only if required, within a 2 hour window.

.EXAMPLE
	PS C:\> $call = @{
		FunctionAppName   = 'func-aum-x1y2z'
		ResourceGroupName = 'rg-aum-automation'
		Endpoint          = 'Start-OneTimeUpdate'
		Parameters        = @{
			TagName              = 'UpdateGroup'
			TagValue             = 'Wave1'
			RebootSetting        = 'Never'
			MaximumDuration      = 'PT3H'
			Classification       = @('Critical', 'Security', 'UpdateRollUp')
			AdditionalExcludedKb = @('KB5034441')
		}
	}
	PS C:\> ./Invoke-UpdateManagerFunction.ps1 @call

	One-time update without reboot, with a 3 hour window and an additional Windows classification.
	KB5034441 is excluded for this run only, on top of the exclusion table.

.EXAMPLE
	PS C:\> $call = @{
		FunctionAppName   = 'func-aum-x1y2z'
		ResourceGroupName = 'rg-aum-automation'
		Endpoint          = 'Start-OneTimeUpdate'
		Parameters        = @{
			MachineName    = @('vm-aum-01', 'vm-aum-02')
			ExclusionScope = 'Wave1'
		}
	}
	PS C:\> ./Invoke-UpdateManagerFunction.ps1 @call

	Installs Critical + Security updates on exactly these two machines (no tag needed), minus the KBs from
	the exclusion table ('Global' + 'Wave1'). Names that are not found are returned in 'NotFound'.

.EXAMPLE
	PS C:\> $call = @{
		FunctionAppName   = 'func-aum-x1y2z'
		ResourceGroupName = 'rg-aum-automation'
		Endpoint          = 'New-UpdateMaintenanceConfiguration'
		Parameters        = @{
			Name           = 'mc-wave1-patch-tuesday'
			StartDateTime  = '2026-10-17 22:00'
			RecurEvery     = 'Month Second Tuesday Offset4'
			Duration       = '03:00'
			ExclusionScope = 'Wave1'
			TagName        = 'UpdateGroup'
			TagValue       = 'Wave1'
		}
	}
	PS C:\> ./Invoke-UpdateManagerFunction.ps1 @call

	Creates a recurring schedule (second Tuesday + 4 days = Saturday, 22:00, 3 hour window, first run 2026-10-17)
	for every machine tagged UpdateGroup=Wave1. The KBs from the exclusion table are excluded in this schedule.

.EXAMPLE
	PS C:\> $call = @{
		FunctionAppName   = 'func-aum-x1y2z'
		ResourceGroupName = 'rg-aum-automation'
		Endpoint          = 'Get-UpdateMaintenanceConfiguration'
		Parameters        = @{ Name = 'mc-wave*' }
	}
	PS C:\> ./Invoke-UpdateManagerFunction.ps1 @call

	Lists all Azure Update Manager schedules whose name starts with 'mc-wave', including their dynamic scopes.

.EXAMPLE
	PS C:\> $call = @{
		FunctionAppName   = 'func-aum-x1y2z'
		ResourceGroupName = 'rg-aum-automation'
		Endpoint          = 'Get-UpdateManagerMachine'
		SubscriptionId    = '00000000-0000-0000-0000-000000000000'
	}
	PS C:\> ./Invoke-UpdateManagerFunction.ps1 @call

	Calls a Function App that lives in a different subscription than the current Az context.#>
#Requires -Version 7.2
#Requires -Modules Az.Accounts
[CmdletBinding()]
[OutputType([psobject])]
param (
	[Parameter(Mandatory)]
	[ValidateNotNullOrEmpty()]
	[string]
	$FunctionAppName,

	[Parameter(Mandatory)]
	[ValidateNotNullOrEmpty()]
	[string]
	$ResourceGroupName,

	[Parameter(Mandatory)]
	[ValidateSet('Start-UpdateAssessment', 'Start-OneTimeUpdate', 'New-UpdateMaintenanceConfiguration', 'Get-UpdateMaintenanceConfiguration', 'Get-UpdateManagerMachine')]
	[string]
	$Endpoint,

	[Parameter()]
	[hashtable]
	$Parameters = @{},

	[Parameter()]
	[ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$', ErrorMessage = "'{0}' is not a valid subscription ID (GUID).")]
	[string]
	$SubscriptionId
)

$ErrorActionPreference = 'Stop'

function Invoke-SiteRequest {
	<#
	.SYNOPSIS
		Calls the Azure Resource Manager (ARM) REST API through the current Az context and returns the parsed JSON.

	.DESCRIPTION
		Thin wrapper around Invoke-AzRestMethod. It authenticates with the signed-in Az context,
		so no token handling is needed.

		Invoke-AzRestMethod does not throw on HTTP errors. This function therefore checks the status code
		and throws for every response with status 400 or higher. The error message contains the method,
		the path, the status code and the response body.

	.PARAMETER Method
		HTTP method. Only GET and POST are needed to read the site and to list its keys.

	.PARAMETER Path
		ARM resource path including the api-version query string, starting with '/subscriptions/...'.
		The path is relative to the ARM endpoint, so no host name is included.

	.EXAMPLE
		PS C:\> $request = @{
			Method = 'GET'
			Path   = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName?api-version=2023-12-01"
		}
		PS C:\> (Invoke-SiteRequest @request).properties.defaultHostName

		Reads the default host name of the Function App.

	.EXAMPLE
		PS C:\> $request = @{
			Method = 'POST'
			Path   = "$siteUri/host/default/listKeys?api-version=2023-12-01"
		}
		PS C:\> (Invoke-SiteRequest @request).functionKeys.default

		Lists the host keys of the Function App and returns the default function key.

	.OUTPUTS
		System.Management.Automation.PSObject. The response body, parsed from JSON.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[ValidateSet('GET', 'POST')]
		[string]
		$Method,

		[Parameter(Mandatory)]
		[string]
		$Path
	)

	$restParam = @{
		Method = $Method
		Path   = $Path
	}
	$response = Invoke-AzRestMethod @restParam
	if ($response.StatusCode -ge 400) { throw "$Method $Path failed ($($response.StatusCode)): $($response.Content)" }
	$response.Content | ConvertFrom-Json
}

$context = Get-AzContext
if (-not $context) { throw "Not signed in. Run 'Connect-AzAccount' first." }
if (-not $SubscriptionId) { $SubscriptionId = $context.Subscription.Id }

$siteUri = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/sites/$FunctionAppName"

# Host name (do not guess it - newer apps can have a unique default host name)
$hostName = (Invoke-SiteRequest -Method GET -Path "$($siteUri)?api-version=2023-12-01").properties.defaultHostName

# Default function key (works for every function with authLevel 'function')
$keys = Invoke-SiteRequest -Method POST -Path "$siteUri/host/default/listKeys?api-version=2023-12-01"
$functionKey = $keys.functionKeys.default

$param = @{
	Method      = 'Post'
	Uri         = "https://$hostName/api/$Endpoint"
	Headers     = @{ 'x-functions-key' = $functionKey }
	ContentType = 'application/json'
	Body        = $Parameters | ConvertTo-Json -Depth 5
}
Invoke-RestMethod @param
