<#
.SYNOPSIS
	Removes everything that the Azure Update Manager automation project created in Azure, Entra ID and GitHub.

.DESCRIPTION
	This is the counterpart of New-GitHubOidcDeploymentIdentity.ps1 and of the Terraform deployment.
	It is destructive. Run it with -WhatIf first to see what would be removed.

	1. Azure workload (skip with -SkipAzure)
	   - Dynamic-scope configuration assignments (subscription level) that point to maintenance configurations
	     in the workload resource group. The Function App creates them, Terraform does not know them.
	   - The custom role 'Update Manager Automation Operator (*)' and its role assignments (subscription level).
	   - Log Analytics workspaces of the resource group are deleted permanently (no 14 day soft delete).
	   - The workload resource group with everything in it: VM, VNet, NAT gateway, Function App, storage,
	     Application Insights, and the maintenance configurations.

	2. Entra ID identity (skip with -SkipIdentity)
	   - All role assignments of the GitHub Actions service principal
	   - The service principal and the app registration (its federated credentials are deleted with it)

	3. Terraform state storage (skip with -SkipStateStorage)
	   - The resource group with the state storage account. The Terraform state is gone afterwards.

	4. GitHub (skip with -SkipGitHub, needs the GitHub CLI 'gh', signed in with the 'repo' scope)
	   - All runs of the workflow (and with them their logs and artifacts)
	   - All deployments of the GitHub environment, then the environment itself
	   - The repository variables AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID and TFSTATE_*.
	     They are removed only if AZURE_CLIENT_ID is the client ID of the app registration removed in step 2.
	     Other workflows of the repository use variables with the same names. If these variables point to
	     another deployment, they stay untouched.

	Not removed:
	- Resource provider registrations (Microsoft.Maintenance, ...). They cost nothing and other workloads may use them.
	- The GitHub workflow file and the code in the repository.

	Required rights of the person running the script:
	- Azure: Owner (or User Access Administrator + Contributor) on the subscription
	- Entra ID: owner of the app registration, or Application Administrator
	- GitHub: admin rights on the repository

.PARAMETER GitHubOrganization
	GitHub user or organization that owns the repository.

.PARAMETER GitHubRepository
	Repository name.

.PARAMETER SubscriptionId
	Subscription of the deployment. Defaults to the current Az context subscription.

.PARAMETER AppDisplayName
	Display name of the app registration created by New-GitHubOidcDeploymentIdentity.ps1.

.PARAMETER GitHubEnvironment
	Name of the GitHub environment used by the apply / deploy jobs.

.PARAMETER WorkflowFileName
	File name of the GitHub Actions workflow whose runs are deleted (in .github/workflows).

.PARAMETER InfraResourceGroupName
	Resource group of the workload (Terraform: rg-<prefix>-automation).

.PARAMETER StateResourceGroupName
	Resource group of the Terraform state storage account.

.PARAMETER SkipAzure
	Do not remove the workload (step 1).

.PARAMETER SkipIdentity
	Do not remove the service principal and app registration (step 2).

.PARAMETER SkipStateStorage
	Do not remove the Terraform state storage (step 3).

.PARAMETER SkipGitHub
	Do not clean up GitHub (step 4).

.PARAMETER Force
	Do not ask for confirmation for every step.

.EXAMPLE
	PS C:\> Connect-AzAccount
	PS C:\> $cleanup = @{
		GitHubOrganization = 'contoso'
		GitHubRepository   = 'AzureUpdateManagerAutomation'
		WhatIf             = $true
	}
	PS C:\> ./Remove-AumDeployment.ps1 @cleanup

	Shows everything that would be removed, without changing anything.

.EXAMPLE
	PS C:\> $cleanup = @{
		GitHubOrganization = 'contoso'
		GitHubRepository   = 'AzureUpdateManagerAutomation'
	}
	PS C:\> ./Remove-AumDeployment.ps1 @cleanup

	Removes everything and asks for confirmation before every step.

.EXAMPLE
	PS C:\> $cleanup = @{
		GitHubOrganization = 'contoso'
		GitHubRepository   = 'AzureUpdateManagerAutomation'
		SubscriptionId     = '00000000-0000-0000-0000-000000000000'
		Force              = $true
	}
	PS C:\> ./Remove-AumDeployment.ps1 @cleanup

	Removes everything in the given subscription without asking.

.EXAMPLE
	PS C:\> $cleanup = @{
		GitHubOrganization = 'contoso'
		GitHubRepository   = 'AzureUpdateManagerAutomation'
		SkipAzure          = $true
		SkipIdentity       = $true
		SkipStateStorage   = $true
	}
	PS C:\> ./Remove-AumDeployment.ps1 @cleanup

	Cleans up GitHub only: workflow runs, deployments, the environment and the repository variables.

.OUTPUTS
	One object per step with the properties Area, Target, Action and Status.
#>
#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Resources
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param (
	[Parameter(Mandatory)]
	[ValidatePattern('^[A-Za-z0-9-]{1,39}$', ErrorMessage = "'{0}' is not a valid GitHub user or organization name.")]
	[string]
	$GitHubOrganization,

	[Parameter(Mandatory)]
	[ValidatePattern('^[A-Za-z0-9._-]{1,100}$', ErrorMessage = "'{0}' is not a valid GitHub repository name.")]
	[string]
	$GitHubRepository,

	[Parameter()]
	[ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$', ErrorMessage = "'{0}' is not a valid subscription ID (GUID).")]
	[string]
	$SubscriptionId,

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[ValidateLength(1, 120)]
	[string]
	$AppDisplayName = "github-oidc-$GitHubRepository",

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]
	$GitHubEnvironment = 'production',

	[Parameter()]
	[ValidatePattern('^[A-Za-z0-9._-]+\.ya?ml$', ErrorMessage = "'{0}' is not a workflow file name (for example deploy.yml).")]
	[string]
	$WorkflowFileName = 'serverless-on-demand-patching-aum.yml',

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[ValidateLength(1, 90)]
	[string]
	$InfraResourceGroupName = 'rg-aum-automation',

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[ValidateLength(1, 90)]
	[string]
	$StateResourceGroupName = 'rg-aum-tfstate',

	[Parameter()]
	[switch]
	$SkipAzure,

	[Parameter()]
	[switch]
	$SkipIdentity,

	[Parameter()]
	[switch]
	$SkipStateStorage,

	[Parameter()]
	[switch]
	$SkipGitHub,

	[Parameter()]
	[switch]
	$Force
)

$ErrorActionPreference = 'Stop'
$env:SuppressAzurePowerShellBreakingChangeWarnings = 'true'
if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference = 'None' }

$script:results = [System.Collections.Generic.List[object]]::new()
$maintenanceApiVersion = '2023-04-01'
$customRoleNamePattern = 'Update Manager Automation Operator (*)'

#region Helpers
function Add-Result {
	<#
	.SYNOPSIS
		Records the outcome of one step and prints it.

	.PARAMETER Area
		Azure, Entra ID, Terraform state or GitHub.

	.PARAMETER Target
		What was (or would be) removed.

	.PARAMETER Action
		What happens to the target.

	.PARAMETER Status
		Removed, Skipped, Not found or Failed.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[string]
		$Area,

		[Parameter(Mandatory)]
		[string]
		$Target,

		[Parameter(Mandatory)]
		[string]
		$Action,

		[Parameter(Mandatory)]
		[string]
		$Status
	)

	$script:results.Add([pscustomobject]@{ Area = $Area; Target = $Target; Action = $Action; Status = $Status })
	Write-Host ("  [{0}] {1}: {2}" -f $Status, $Action, $Target)
}

function Invoke-ArmDelete {
	<#
	.SYNOPSIS
		Sends an ARM DELETE request through the Az context and throws on errors other than 404.

	.PARAMETER Path
		ARM resource path including the api-version query string.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[string]
		$Path
	)

	$response = Invoke-AzRestMethod -Method DELETE -Path $Path
	if ($response.StatusCode -ge 400 -and $response.StatusCode -ne 404) {
		throw "DELETE $Path failed ($($response.StatusCode)): $($response.Content)"
	}
}

function Get-OwnConfigurationAssignment {
	<#
	.SYNOPSIS
		Finds the subscription-level configuration assignments (dynamic scopes) that point to maintenance configurations in the workload resource group.

	.DESCRIPTION
		Azure has no reliable list operation for subscription-level configuration assignments: the list API
		returns 'NotImplemented' in many subscriptions. The function tries the list API first and falls back to
		Azure Resource Graph (table maintenanceresources). If neither finds anything while the resource group
		contains maintenance configurations, it warns, because assignments may exist that could not be enumerated.

	.PARAMETER SubscriptionScope
		'/subscriptions/<id>'.

	.PARAMETER ResourceGroupPath
		'/subscriptions/<id>/resourceGroups/<name>' of the workload.

	.PARAMETER ApiVersion
		API version of Microsoft.Maintenance.

	.OUTPUTS
		Objects with the properties Id and Name.
	#>
	[CmdletBinding()]
	[OutputType([pscustomobject])]
	param (
		[Parameter(Mandatory)]
		[string]
		$SubscriptionScope,

		[Parameter(Mandatory)]
		[string]
		$ResourceGroupPath,

		[Parameter()]
		[string]
		$ApiVersion = '2023-04-01'
	)

	$configurationPrefix = "$ResourceGroupPath/providers/Microsoft.Maintenance/maintenanceConfigurations/"
	$found = [System.Collections.Generic.List[object]]::new()

	$path = "$SubscriptionScope/providers/Microsoft.Maintenance/configurationAssignments?api-version=$ApiVersion"
	$listWorked = $true
	while ($path) {
		$page = Invoke-AzRestMethod -Method GET -Path $path
		if ($page.StatusCode -ge 400) { $listWorked = $false; break }
		$pageContent = $page.Content | ConvertFrom-Json
		foreach ($item in @($pageContent.value)) {
			if ($item.properties.maintenanceConfigurationId -like "$configurationPrefix*") { $found.Add([pscustomobject]@{ Id = $item.id; Name = $item.name }) }
		}
		$path = $pageContent.nextLink -replace '^https://management\.azure\.com', ''
	}

	if (-not $found) {
		$graphQuery = "maintenanceresources | where type contains 'configurationassignments' | where tolower(tostring(properties.maintenanceConfigurationId)) startswith '$($configurationPrefix.ToLower())' | project id, name"
		$graphBody = @{ subscriptions = @($SubscriptionScope -replace '^/subscriptions/', ''); query = $graphQuery } | ConvertTo-Json
		# Read-only query: it must run even with -WhatIf
		$graph = Invoke-AzRestMethod -Method POST -Path '/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' -Payload $graphBody -WhatIf:$false -Confirm:$false
		if ($graph.StatusCode -lt 400) {
			foreach ($row in @(($graph.Content | ConvertFrom-Json).data)) { $found.Add([pscustomobject]@{ Id = $row.id; Name = $row.name }) }
		}
	}

	if (-not $found -and -not $listWorked) {
		$configurations = @(Get-AzResource -ResourceGroupName ($ResourceGroupPath -replace '^.*/resourceGroups/', '') -ResourceType 'Microsoft.Maintenance/maintenanceConfigurations' -ErrorAction Ignore)
		if ($configurations) {
			Write-Warning "Could not list configuration assignments (dynamic scopes). Delete them by hand if you created some: PUT/DELETE $SubscriptionScope/providers/Microsoft.Maintenance/configurationAssignments/<name>. Configurations: $($configurations.Name -join ', ')"
		}
	}
	$found
}
function Invoke-GitHubCli {
	<#
	.SYNOPSIS
		Runs the GitHub CLI and returns its output. Throws when gh fails, unless -IgnoreError is set.

	.PARAMETER Argument
		Arguments for gh, for example 'api', 'repos/org/repo'.

	.PARAMETER IgnoreError
		Return $null instead of throwing, for example to probe for a resource that may not exist.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory)]
		[string[]]
		$Argument,

		[Parameter()]
		[switch]
		$IgnoreError
	)

	$output = & gh @Argument 2>&1
	if ($LASTEXITCODE -ne 0) {
		if ($IgnoreError) { return $null }
		throw "gh $($Argument -join ' ') failed: $($output -join ' ')"
	}
	$output
}
#endregion Helpers

#region Context
$context = Get-AzContext
if (-not $context) { throw "Not signed in. Run 'Connect-AzAccount' first." }
if ($SubscriptionId -and $SubscriptionId -ne $context.Subscription.Id) {
	$context = Set-AzContext -Subscription $SubscriptionId
}
$SubscriptionId = $context.Subscription.Id
$subscriptionScope = "/subscriptions/$SubscriptionId"
$repoFullName = "$GitHubOrganization/$GitHubRepository"

if (-not $SkipGitHub) {
	if (-not (Get-Command gh -ErrorAction Ignore)) { throw 'GitHub CLI (gh) not found. Install it or run with -SkipGitHub.' }
	$null = Invoke-GitHubCli -Argument 'auth', 'status'
}

# Needed for the GitHub variable check, so read it before the app registration is deleted
$apps = @(Get-AzADApplication -DisplayName $AppDisplayName | Where-Object DisplayName -eq $AppDisplayName)
$removedClientIds = @($apps.AppId)

Write-Host "Subscription: $SubscriptionId | Repository: $repoFullName | WhatIf: $([bool]$WhatIfPreference)"
#endregion Context

#region 1. Azure workload
if (-not $SkipAzure) {
	Write-Host "`n[1/4] Azure workload"
	$infraRgPath = "$subscriptionScope/resourceGroups/$InfraResourceGroupName"

	# Dynamic scopes: configuration assignments live on the subscription, outside the resource group
	$ownAssignments = @(Get-OwnConfigurationAssignment -SubscriptionScope $subscriptionScope -ResourceGroupPath $infraRgPath -ApiVersion $maintenanceApiVersion)
	foreach ($assignment in $ownAssignments) {
		$action = 'Delete configuration assignment'
		if ($PSCmdlet.ShouldProcess($assignment.Name, $action)) {
			Invoke-ArmDelete -Path "$($assignment.Id)?api-version=$maintenanceApiVersion"
			Add-Result -Area 'Azure' -Target $assignment.Name -Action $action -Status 'Removed'
		}
		else { Add-Result -Area 'Azure' -Target $assignment.Name -Action $action -Status 'Skipped' }
	}
	if (-not $ownAssignments) { Add-Result -Area 'Azure' -Target "configuration assignments for $InfraResourceGroupName" -Action 'Delete configuration assignment' -Status 'Not found' }

	# Custom role of the Function App's Managed Identity: assignments first, then the definition
	$roles = @(Get-AzRoleDefinition -Custom | Where-Object Name -like $customRoleNamePattern)
	foreach ($role in $roles) {
		foreach ($roleAssignment in @(Get-AzRoleAssignment -RoleDefinitionId $role.Id -Scope $subscriptionScope)) {
			$action = 'Delete role assignment'
			$target = "$($role.Name) -> $($roleAssignment.ObjectId)"
			if ($PSCmdlet.ShouldProcess($target, $action)) {
				$null = Remove-AzRoleAssignment -InputObject $roleAssignment
				Add-Result -Area 'Azure' -Target $target -Action $action -Status 'Removed'
			}
			else { Add-Result -Area 'Azure' -Target $target -Action $action -Status 'Skipped' }
		}
		$action = 'Delete custom role'
		if ($PSCmdlet.ShouldProcess($role.Name, $action)) {
			$null = Remove-AzRoleDefinition -Id $role.Id -Force
			Add-Result -Area 'Azure' -Target $role.Name -Action $action -Status 'Removed'
		}
		else { Add-Result -Area 'Azure' -Target $role.Name -Action $action -Status 'Skipped' }
	}
	if (-not $roles) { Add-Result -Area 'Azure' -Target $customRoleNamePattern -Action 'Delete custom role' -Status 'Not found' }

	$infraResourceGroup = Get-AzResourceGroup -Name $InfraResourceGroupName -ErrorAction Ignore
	if ($infraResourceGroup) {
		# A deleted workspace stays recoverable for 14 days and blocks its name. Delete it permanently.
		foreach ($workspace in @(Get-AzResource -ResourceGroupName $InfraResourceGroupName -ResourceType 'Microsoft.OperationalInsights/workspaces')) {
			$action = 'Delete Log Analytics workspace permanently'
			if ($PSCmdlet.ShouldProcess($workspace.Name, $action)) {
				Invoke-ArmDelete -Path "$($workspace.ResourceId)?api-version=2023-09-01&force=true"
				Add-Result -Area 'Azure' -Target $workspace.Name -Action $action -Status 'Removed'
			}
			else { Add-Result -Area 'Azure' -Target $workspace.Name -Action $action -Status 'Skipped' }
		}

		$action = 'Delete resource group'
		if ($PSCmdlet.ShouldProcess($InfraResourceGroupName, $action)) {
			$null = Remove-AzResourceGroup -Name $InfraResourceGroupName -Force
			Add-Result -Area 'Azure' -Target $InfraResourceGroupName -Action $action -Status 'Removed'
		}
		else { Add-Result -Area 'Azure' -Target $InfraResourceGroupName -Action $action -Status 'Skipped' }
	}
	else { Add-Result -Area 'Azure' -Target $InfraResourceGroupName -Action 'Delete resource group' -Status 'Not found' }
}
#endregion

#region 2. Entra ID identity
if (-not $SkipIdentity) {
	Write-Host "`n[2/4] Entra ID identity '$AppDisplayName'"
	foreach ($app in $apps) {
		$servicePrincipal = Get-AzADServicePrincipal -ApplicationId $app.AppId
		if ($servicePrincipal) {
			foreach ($roleAssignment in @(Get-AzRoleAssignment -ObjectId $servicePrincipal.Id)) {
				$action = 'Delete role assignment'
				$target = "$($roleAssignment.RoleDefinitionName) on $($roleAssignment.Scope)"
				if ($PSCmdlet.ShouldProcess($target, $action)) {
					$null = Remove-AzRoleAssignment -InputObject $roleAssignment
					Add-Result -Area 'Entra ID' -Target $target -Action $action -Status 'Removed'
				}
				else { Add-Result -Area 'Entra ID' -Target $target -Action $action -Status 'Skipped' }
			}

			$action = 'Delete service principal'
			if ($PSCmdlet.ShouldProcess($servicePrincipal.DisplayName, $action)) {
				Remove-AzADServicePrincipal -ObjectId $servicePrincipal.Id
				Add-Result -Area 'Entra ID' -Target $servicePrincipal.Id -Action $action -Status 'Removed'
			}
			else { Add-Result -Area 'Entra ID' -Target $servicePrincipal.Id -Action $action -Status 'Skipped' }
		}

		$action = 'Delete app registration (and its federated credentials)'
		if ($PSCmdlet.ShouldProcess("$($app.DisplayName) ($($app.AppId))", $action)) {
			Remove-AzADApplication -ObjectId $app.Id
			Add-Result -Area 'Entra ID' -Target $app.AppId -Action $action -Status 'Removed'
		}
		else { Add-Result -Area 'Entra ID' -Target $app.AppId -Action $action -Status 'Skipped' }
	}
	if (-not $apps) { Add-Result -Area 'Entra ID' -Target $AppDisplayName -Action 'Delete app registration' -Status 'Not found' }
}
#endregion

#region 3. Terraform state storage
if (-not $SkipStateStorage) {
	Write-Host "`n[3/4] Terraform state storage"
	$stateResourceGroup = Get-AzResourceGroup -Name $StateResourceGroupName -ErrorAction Ignore
	if ($stateResourceGroup) {
		$resourceCount = @(Get-AzResource -ResourceGroupName $StateResourceGroupName).Count
		if ($resourceCount -gt 1) { Write-Warning "Resource group '$StateResourceGroupName' contains $resourceCount resources. All of them are deleted." }
		$action = 'Delete resource group (Terraform state is lost)'
		if ($PSCmdlet.ShouldProcess($StateResourceGroupName, $action)) {
			$null = Remove-AzResourceGroup -Name $StateResourceGroupName -Force
			Add-Result -Area 'Terraform state' -Target $StateResourceGroupName -Action $action -Status 'Removed'
		}
		else { Add-Result -Area 'Terraform state' -Target $StateResourceGroupName -Action $action -Status 'Skipped' }
	}
	else { Add-Result -Area 'Terraform state' -Target $StateResourceGroupName -Action 'Delete resource group' -Status 'Not found' }
}
#endregion

#region 4. GitHub
if (-not $SkipGitHub) {
	Write-Host "`n[4/4] GitHub repository $repoFullName"

	# Workflow runs. Runs that are still active cannot be deleted, so cancel them first.
	$runLines = @(Invoke-GitHubCli -Argument 'api', '--paginate', "repos/$repoFullName/actions/workflows/$WorkflowFileName/runs?per_page=100", '--jq', '.workflow_runs[] | "\(.id) \(.status)"' -IgnoreError)
	$runs = @($runLines | Where-Object { $_ -match '^\d+ ' } | ForEach-Object { $id, $status = $_ -split ' '; [pscustomobject]@{ Id = $id; Status = $status } })
	$action = "Delete workflow runs of $WorkflowFileName"
	if ($runs) {
		if ($PSCmdlet.ShouldProcess("$($runs.Count) run(s)", $action)) {
			foreach ($run in $runs) {
				if ($run.Status -ne 'completed') {
					$null = Invoke-GitHubCli -Argument 'api', '--method', 'POST', "repos/$repoFullName/actions/runs/$($run.Id)/force-cancel" -IgnoreError
					for ($attempt = 1; $attempt -le 15; $attempt++) {
						$state = Invoke-GitHubCli -Argument 'api', "repos/$repoFullName/actions/runs/$($run.Id)", '--jq', '.status' -IgnoreError
						if ($state -eq 'completed') { break }
						Start-Sleep -Seconds 2
					}
				}
				$null = Invoke-GitHubCli -Argument 'api', '--method', 'DELETE', "repos/$repoFullName/actions/runs/$($run.Id)"
			}
			Add-Result -Area 'GitHub' -Target "$($runs.Count) run(s)" -Action $action -Status 'Removed'
		}
		else { Add-Result -Area 'GitHub' -Target "$($runs.Count) run(s)" -Action $action -Status 'Skipped' }
	}
	else { Add-Result -Area 'GitHub' -Target $WorkflowFileName -Action $action -Status 'Not found' }

	# Environment: deployments must be inactive before they can be deleted
	$environmentExists = $null -ne (Invoke-GitHubCli -Argument 'api', "repos/$repoFullName/environments/$GitHubEnvironment", '--jq', '.name' -IgnoreError)
	if ($environmentExists) {
		$deploymentIds = @(Invoke-GitHubCli -Argument 'api', '--paginate', "repos/$repoFullName/deployments?environment=$GitHubEnvironment&per_page=100", '--jq', '.[].id' -IgnoreError | Where-Object { $_ -match '^\d+$' })
		$action = 'Delete deployments'
		if ($deploymentIds) {
			if ($PSCmdlet.ShouldProcess("$($deploymentIds.Count) deployment(s) of '$GitHubEnvironment'", $action)) {
				foreach ($deploymentId in $deploymentIds) {
					$null = Invoke-GitHubCli -Argument 'api', '--method', 'POST', "repos/$repoFullName/deployments/$deploymentId/statuses", '-f', 'state=inactive' -IgnoreError
					$null = Invoke-GitHubCli -Argument 'api', '--method', 'DELETE', "repos/$repoFullName/deployments/$deploymentId" -IgnoreError
				}
				Add-Result -Area 'GitHub' -Target "$($deploymentIds.Count) deployment(s)" -Action $action -Status 'Removed'
			}
			else { Add-Result -Area 'GitHub' -Target "$($deploymentIds.Count) deployment(s)" -Action $action -Status 'Skipped' }
		}

		$action = 'Delete environment'
		if ($PSCmdlet.ShouldProcess($GitHubEnvironment, $action)) {
			$null = Invoke-GitHubCli -Argument 'api', '--method', 'DELETE', "repos/$repoFullName/environments/$GitHubEnvironment"
			Add-Result -Area 'GitHub' -Target $GitHubEnvironment -Action $action -Status 'Removed'
		}
		else { Add-Result -Area 'GitHub' -Target $GitHubEnvironment -Action $action -Status 'Skipped' }
	}
	else { Add-Result -Area 'GitHub' -Target $GitHubEnvironment -Action 'Delete environment' -Status 'Not found' }

	# Repository variables: other workflows share these names, so only remove them if they belong to this deployment
	$variableNames = 'AZURE_CLIENT_ID', 'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'TFSTATE_RESOURCE_GROUP', 'TFSTATE_STORAGE_ACCOUNT', 'TFSTATE_CONTAINER'
	$variablesJson = Invoke-GitHubCli -Argument 'variable', 'list', '--repo', $repoFullName, '--json', 'name,value'
	$variables = @($variablesJson | ConvertFrom-Json | Where-Object name -in $variableNames)
	$clientIdVariable = $variables | Where-Object name -eq 'AZURE_CLIENT_ID'
	if (-not $variables) {
		Add-Result -Area 'GitHub' -Target 'repository variables' -Action 'Delete variables' -Status 'Not found'
	}
	elseif (-not $clientIdVariable -or $clientIdVariable.value -notin $removedClientIds) {
		Write-Warning "AZURE_CLIENT_ID does not belong to '$AppDisplayName' (or that app registration is already gone). The repository variables are left untouched because other workflows may use them."
		Add-Result -Area 'GitHub' -Target 'repository variables' -Action 'Delete variables' -Status 'Skipped'
	}
	else {
		foreach ($variable in $variables) {
			$action = 'Delete variable'
			if ($PSCmdlet.ShouldProcess($variable.name, $action)) {
				$null = Invoke-GitHubCli -Argument 'variable', 'delete', $variable.name, '--repo', $repoFullName
				Add-Result -Area 'GitHub' -Target $variable.name -Action $action -Status 'Removed'
			}
			else { Add-Result -Area 'GitHub' -Target $variable.name -Action $action -Status 'Skipped' }
		}
		Write-Warning 'These variables were also read by the other workflows of this repository (for example csv-upload-to-azure-sql). Run their bootstrap script again if you still use them.'
	}
}
#endregion

Write-Host "`nDone."
$script:results
