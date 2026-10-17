<#
.SYNOPSIS
	Removes everything that the Dev Containers Part 2 project created in Azure, Entra ID and GitHub.

.DESCRIPTION
	This is the counterpart of New-GitHubOidcDeploymentIdentity.ps1, of the Terraform deployment,
	of the GitHub workflow and of Set-CodespacesRegistrySecret.ps1.
	It is destructive. Run it with -WhatIf first to see what would be removed.

	1. Role assignments (skip with -SkipIdentity)
	   - All role assignments of the infra and the image service principal
	     (Contributor, Role Based Access Control Administrator, Storage Blob Data Contributor, AcrPush)
	   - All role assignments directly on the container registry (AcrPull for the team)

	2. Azure workload (skip with -SkipAzure)
	   - The workload resource group with everything in it: the container registry with all images,
	     attestations, the scope map and the Codespaces token

	3. Terraform state storage (skip with -SkipStateStorage)
	   - The resource group with the state storage account. The Terraform state is gone afterwards.

	4. Entra ID (skip with -SkipIdentity)
	   - Both service principals and app registrations (their federated credentials are deleted with them)
	   - The AcrPull security group (only with -AcrPullGroupName, and only if New-GitHubOidcDeploymentIdentity.ps1
	     created it - a group with another description is left untouched)

	5. GitHub (skip with -SkipGitHub, needs the GitHub CLI 'gh', signed in with the 'repo' scope)
	   - All runs of the workflow (and with them their logs and artifacts)
	   - The GitHub Actions cache entries of the image build (Docker layer cache)
	   - All deployments of the GitHub environment, then the environment itself
	   - The repository variables written by the bootstrap script. They are removed only if
	     AZURE_INFRA_CLIENT_ID is the client ID of the infra app registration removed in step 4.
	     Variables that point to another deployment stay untouched.
	   - The Codespaces secrets <SecretPrefix>_CONTAINER_REGISTRY_SERVER / _USER / _PASSWORD

	Not removed:
	- Resource provider registrations (Microsoft.ContainerRegistry, Microsoft.Storage). They cost nothing
	  and other workloads may use them.
	- The workflow files and the code in the repository.
	- Docker credentials on your own machine. Remove them with 'docker logout <registry>.azurecr.io'.

	Required rights of the person running the script:
	- Azure: Owner (or User Access Administrator + Contributor) on the subscription
	- Entra ID: owner of the app registrations, or Application Administrator
	- Entra ID (only with -AcrPullGroupName): owner of the group, or Groups Administrator
	- GitHub: admin rights on the repository

.PARAMETER GitHubOrganization
	GitHub user or organization that owns the repository.

.PARAMETER GitHubRepository
	Repository name.

.PARAMETER SubscriptionId
	Subscription of the deployment. Defaults to the current Az context subscription.

.PARAMETER ResourceGroupName
	Workload resource group with the container registry.

.PARAMETER StateResourceGroupName
	Resource group of the Terraform state storage account.

.PARAMETER InfraAppDisplayName
	Display name of the app registration that runs Terraform.

.PARAMETER ImageAppDisplayName
	Display name of the app registration that pushes the image.

.PARAMETER GitHubEnvironment
	Name of the GitHub environment used by the Terraform apply job.

.PARAMETER AcrPullGroupName
	Display name of the AcrPull security group that New-GitHubOidcDeploymentIdentity.ps1 created.
	Without it, no group is deleted.

.PARAMETER WorkflowFileName
	File names of the GitHub Actions workflows whose runs are deleted (in .github/workflows).

.PARAMETER CacheScope
	Scope of the Docker layer cache in the image workflow (cache-from / cache-to type=gha,scope=...).

.PARAMETER SecretPrefix
	Prefix of the Codespaces secrets written by Set-CodespacesRegistrySecret.ps1.

.PARAMETER SkipAzure
	Do not remove the workload resource group (step 2).

.PARAMETER SkipIdentity
	Do not remove role assignments, service principals and app registrations (steps 1 and 4).

.PARAMETER SkipStateStorage
	Do not remove the Terraform state storage (step 3).

.PARAMETER SkipGitHub
	Do not clean up GitHub (step 5).

.PARAMETER Force
	Do not ask for confirmation for every step.

.EXAMPLE
	PS C:\> Connect-AzAccount
	PS C:\> $cleanup = @{
		GitHubOrganization = 'contoso'
		GitHubRepository   = 'BlogAssets'
		WhatIf             = $true
	}
	PS C:\> ./Remove-DevContainerRegistryDeployment.ps1 @cleanup

	Shows everything that would be removed, without changing anything.

.EXAMPLE
	PS C:\> $cleanup = @{
		GitHubOrganization = 'contoso'
		GitHubRepository   = 'BlogAssets'
	}
	PS C:\> ./Remove-DevContainerRegistryDeployment.ps1 @cleanup

	Removes everything and asks for confirmation before every step.

.EXAMPLE
	PS C:\> $cleanup = @{
		GitHubOrganization = 'contoso'
		GitHubRepository   = 'BlogAssets'
		AcrPullGroupName   = 'grp-devcontainer-acrpull'
	}
	PS C:\> ./Remove-DevContainerRegistryDeployment.ps1 @cleanup

	Removes everything, including the AcrPull group grp-devcontainer-acrpull.

.EXAMPLE
	PS C:\> $cleanup = @{
		GitHubOrganization = 'contoso'
		GitHubRepository   = 'BlogAssets'
		SubscriptionId     = '00000000-0000-0000-0000-000000000000'
		Force              = $true
	}
	PS C:\> ./Remove-DevContainerRegistryDeployment.ps1 @cleanup

	Removes everything in the given subscription without asking.

.EXAMPLE
	PS C:\> $cleanup = @{
		GitHubOrganization = 'contoso'
		GitHubRepository   = 'BlogAssets'
		SkipGitHub         = $true
	}
	PS C:\> ./Remove-DevContainerRegistryDeployment.ps1 @cleanup

	Cleans up Azure and Entra ID only. GitHub stays as it is.

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
	[ValidateLength(1, 90)]
	[string]
	$ResourceGroupName = 'rg-devcontainer-registry',

	[Parameter()]
	[ValidateLength(1, 90)]
	[string]
	$StateResourceGroupName = 'rg-devcontainer-tfstate',

	[Parameter()]
	[ValidateLength(1, 120)]
	[string]
	$InfraAppDisplayName = "github-oidc-$GitHubRepository-devcontainer-infra",

	[Parameter()]
	[ValidateLength(1, 120)]
	[string]
	$ImageAppDisplayName = "github-oidc-$GitHubRepository-devcontainer-image",

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]
	$GitHubEnvironment = 'devcontainer-registry',

	[Parameter()]
	[ValidateLength(1, 256)]
	[string]
	$AcrPullGroupName,

	[Parameter()]
	[ValidatePattern('^[A-Za-z0-9._-]+\.ya?ml$', ErrorMessage = "'{0}' is not a workflow file name (for example deploy.yml).")]
	[string[]]
	$WorkflowFileName = @('dev-containers-part-2.yml'),

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]
	$CacheScope = 'devcontainer-devops',

	[Parameter()]
	[ValidatePattern('^[A-Z][A-Z0-9_]*$', ErrorMessage = "'{0}' must be upper case letters, digits and underscores.")]
	[string]
	$SecretPrefix = 'ACR',

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

	.EXAMPLE
		PS C:\> Add-Result -Area 'Azure' -Target 'rg-devcontainer-registry' -Action 'Delete resource group' -Status 'Removed'

		Records and prints one line of the summary.
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

function Remove-RoleAssignmentWithConfirm {
	<#
	.SYNOPSIS
		Removes one role assignment after ShouldProcess and records the result.

	.PARAMETER RoleAssignment
		The role assignment from Get-AzRoleAssignment.

	.PARAMETER Area
		Area for the summary.

	.EXAMPLE
		PS C:\> Get-AzRoleAssignment -ObjectId $sp.Id | ForEach-Object { Remove-RoleAssignmentWithConfirm -RoleAssignment $_ -Area 'Entra ID' }

		Removes every role assignment of the service principal, one confirmation each.
	#>
	[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
	param (
		[Parameter(Mandatory)]
		[object]
		$RoleAssignment,

		[Parameter(Mandatory)]
		[string]
		$Area
	)

	$action = 'Delete role assignment'
	$principal = if ($RoleAssignment.DisplayName) { $RoleAssignment.DisplayName } else { $RoleAssignment.ObjectId }
	$target = "$($RoleAssignment.RoleDefinitionName) for $principal on $($RoleAssignment.Scope)"
	if ($PSCmdlet.ShouldProcess($target, $action)) {
		$null = Remove-AzRoleAssignment -InputObject $RoleAssignment
		Add-Result -Area $Area -Target $target -Action $action -Status 'Removed'
	}
	else { Add-Result -Area $Area -Target $target -Action $action -Status 'Skipped' }
}

function Invoke-GitHubCli {
	<#
	.SYNOPSIS
		Runs the GitHub CLI and returns its output. Throws when gh fails, unless -IgnoreError is set.

	.PARAMETER Argument
		Arguments for gh, for example 'api', 'repos/org/repo'.

	.PARAMETER IgnoreError
		Return $null instead of throwing, for example to probe for a resource that may not exist.

	.EXAMPLE
		PS C:\> Invoke-GitHubCli -Argument 'api', 'repos/contoso/BlogAssets' -IgnoreError

		Returns the repository JSON, or $null if the call fails.
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
$repoFullName = "$GitHubOrganization/$GitHubRepository"

if (-not $SkipGitHub) {
	if (-not (Get-Command gh -ErrorAction Ignore)) { throw 'GitHub CLI (gh) not found. Install it or run with -SkipGitHub.' }
	$null = Invoke-GitHubCli -Argument 'auth', 'status'
}

# Read the identities before anything is deleted: the GitHub variable check needs the client ID
$identities = foreach ($displayName in $InfraAppDisplayName, $ImageAppDisplayName) {
	foreach ($app in @(Get-AzADApplication -DisplayName $displayName | Where-Object DisplayName -eq $displayName)) {
		[pscustomobject]@{
			DisplayName      = $displayName
			App              = $app
			ServicePrincipal = Get-AzADServicePrincipal -ApplicationId $app.AppId
		}
	}
}
$infraClientIds = @($identities | Where-Object DisplayName -eq $InfraAppDisplayName | ForEach-Object { $_.App.AppId })
$registries = @(Get-AzResource -ResourceGroupName $ResourceGroupName -ResourceType 'Microsoft.ContainerRegistry/registries' -ErrorAction Ignore)

Write-Host "Subscription: $SubscriptionId | Repository: $repoFullName | WhatIf: $([bool]$WhatIfPreference)"
#endregion Context

#region 1. Role assignments
if (-not $SkipIdentity) {
	Write-Host "`n[1/5] Role assignments"
	# Assignments of both deployment identities, wherever they are (resource group, state container, registry)
	$found = $false
	foreach ($identity in $identities | Where-Object ServicePrincipal) {
		foreach ($roleAssignment in @(Get-AzRoleAssignment -ObjectId $identity.ServicePrincipal.Id)) {
			$found = $true
			Remove-RoleAssignmentWithConfirm -RoleAssignment $roleAssignment -Area 'Entra ID'
		}
	}
	# Assignments directly on the registry, e.g. AcrPull for the team group (inherited ones are skipped)
	foreach ($registry in $registries) {
		foreach ($roleAssignment in @(Get-AzRoleAssignment -Scope $registry.ResourceId | Where-Object Scope -eq $registry.ResourceId)) {
			if ($identities.ServicePrincipal.Id -contains $roleAssignment.ObjectId) { continue }
			$found = $true
			Remove-RoleAssignmentWithConfirm -RoleAssignment $roleAssignment -Area 'Azure'
		}
	}
	if (-not $found) { Add-Result -Area 'Entra ID' -Target 'deployment identities and registry' -Action 'Delete role assignment' -Status 'Not found' }
}
#endregion

#region 2. Azure workload
if (-not $SkipAzure) {
	Write-Host "`n[2/5] Azure workload"
	if (Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction Ignore) {
		$names = ($registries.Name -join ', ')
		$action = 'Delete resource group (registry and all images are lost)'
		if ($PSCmdlet.ShouldProcess("$ResourceGroupName [$names]", $action)) {
			$null = Remove-AzResourceGroup -Name $ResourceGroupName -Force
			Add-Result -Area 'Azure' -Target $ResourceGroupName -Action $action -Status 'Removed'
		}
		else { Add-Result -Area 'Azure' -Target $ResourceGroupName -Action $action -Status 'Skipped' }
	}
	else { Add-Result -Area 'Azure' -Target $ResourceGroupName -Action 'Delete resource group' -Status 'Not found' }
}
#endregion

#region 3. Terraform state storage
if (-not $SkipStateStorage) {
	Write-Host "`n[3/5] Terraform state storage"
	if (Get-AzResourceGroup -Name $StateResourceGroupName -ErrorAction Ignore) {
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

#region 4. Entra ID
if (-not $SkipIdentity) {
	Write-Host "`n[4/5] Entra ID app registrations"
	foreach ($identity in $identities) {
		if ($identity.ServicePrincipal) {
			$action = 'Delete service principal'
			if ($PSCmdlet.ShouldProcess("$($identity.DisplayName) ($($identity.ServicePrincipal.Id))", $action)) {
				Remove-AzADServicePrincipal -ObjectId $identity.ServicePrincipal.Id
				Add-Result -Area 'Entra ID' -Target $identity.ServicePrincipal.Id -Action $action -Status 'Removed'
			}
			else { Add-Result -Area 'Entra ID' -Target $identity.ServicePrincipal.Id -Action $action -Status 'Skipped' }
		}

		$action = 'Delete app registration (and its federated credentials)'
		if ($PSCmdlet.ShouldProcess("$($identity.DisplayName) ($($identity.App.AppId))", $action)) {
			Remove-AzADApplication -ObjectId $identity.App.Id
			Add-Result -Area 'Entra ID' -Target "$($identity.DisplayName) ($($identity.App.AppId))" -Action $action -Status 'Removed'
		}
		else { Add-Result -Area 'Entra ID' -Target "$($identity.DisplayName) ($($identity.App.AppId))" -Action $action -Status 'Skipped' }
	}
	if (-not $identities) { Add-Result -Area 'Entra ID' -Target "$InfraAppDisplayName, $ImageAppDisplayName" -Action 'Delete app registration' -Status 'Not found' }

	if ($AcrPullGroupName) {
		$action = 'Delete AcrPull group'
		$pullGroups = @(Get-AzADGroup -DisplayName $AcrPullGroupName | Where-Object DisplayName -eq $AcrPullGroupName)
		if (-not $pullGroups) {
			Add-Result -Area 'Entra ID' -Target $AcrPullGroupName -Action $action -Status 'Not found'
		}
		foreach ($pullGroup in $pullGroups) {
			$target = "$AcrPullGroupName ($($pullGroup.Id))"
			# Only delete the group the bootstrap script created - a group with that name may be used elsewhere
			if ($pullGroup.Description -notlike '*Created by New-GitHubOidcDeploymentIdentity.ps1*') {
				Write-Warning "Group $target was not created by New-GitHubOidcDeploymentIdentity.ps1. It is left untouched."
				Add-Result -Area 'Entra ID' -Target $target -Action $action -Status 'Skipped'
				continue
			}
			if ($PSCmdlet.ShouldProcess($target, $action)) {
				Remove-AzADGroup -ObjectId $pullGroup.Id
				Add-Result -Area 'Entra ID' -Target $target -Action $action -Status 'Removed'
			} else {
				Add-Result -Area 'Entra ID' -Target $target -Action $action -Status 'Skipped'
			}
		}
	}
}
#endregion

#region 5. GitHub
if (-not $SkipGitHub) {
	Write-Host "`n[5/5] GitHub repository $repoFullName"

	# Workflow runs. Runs that are still active cannot be deleted, so cancel them first.
	foreach ($workflow in $WorkflowFileName) {
		$runLines = @(Invoke-GitHubCli -Argument 'api', '--paginate', "repos/$repoFullName/actions/workflows/$workflow/runs?per_page=100", '--jq', '.workflow_runs[] | "\(.id) \(.status)"' -IgnoreError)
		$runs = @($runLines | Where-Object { $_ -match '^\d+ ' } | ForEach-Object { $id, $status = $_ -split ' '; [pscustomobject]@{ Id = $id; Status = $status } })
		$action = "Delete workflow runs of $workflow"
		if (-not $runs) { Add-Result -Area 'GitHub' -Target $workflow -Action $action -Status 'Not found'; continue }
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

	# Docker layer cache of the image build (cache-to: type=gha,scope=<CacheScope>).
	# BuildKit stores the cache index under a key with the scope, and the layers as 'buildkit-blob-...'.
	# The layers have no scope in their key - in this repository only the image workflow uses BuildKit.
	$cacheLines = @(Invoke-GitHubCli -Argument 'api', '--paginate', "repos/$repoFullName/actions/caches?per_page=100", '--jq', '.actions_caches[] | "\(.id) \(.key)"' -IgnoreError)
	$caches = @($cacheLines | Where-Object { $_ -match '^\d+ ' } | ForEach-Object { $id, $key = $_ -split ' ', 2; [pscustomobject]@{ Id = $id; Key = $key } } |
		Where-Object { $_.Key -like "*$CacheScope*" -or $_.Key -like 'buildkit-blob-*' })
	$action = 'Delete GitHub Actions cache entries (Docker layers)'
	if ($caches) {
		if ($PSCmdlet.ShouldProcess("$($caches.Count) cache entr(ies)", $action)) {
			foreach ($cache in $caches) { $null = Invoke-GitHubCli -Argument 'api', '--method', 'DELETE', "repos/$repoFullName/actions/caches/$($cache.Id)" -IgnoreError }
			Add-Result -Area 'GitHub' -Target "$($caches.Count) cache entr(ies)" -Action $action -Status 'Removed'
		}
		else { Add-Result -Area 'GitHub' -Target "$($caches.Count) cache entr(ies)" -Action $action -Status 'Skipped' }
	}
	else { Add-Result -Area 'GitHub' -Target "cache scope $CacheScope" -Action $action -Status 'Not found' }

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

	# Repository variables of the bootstrap script. Only removed if they belong to this deployment.
	$variableNames = @(
		'AZURE_TENANT_ID', 'AZURE_SUBSCRIPTION_ID', 'AZURE_INFRA_CLIENT_ID', 'AZURE_IMAGE_CLIENT_ID', 'AZURE_IMAGE_PRINCIPAL_ID'
		'AZURE_RESOURCE_GROUP', 'ACR_NAME', 'ACR_PULL_PRINCIPAL_IDS'
		'TFSTATE_RESOURCE_GROUP', 'TFSTATE_STORAGE_ACCOUNT', 'TFSTATE_CONTAINER'
	)
	$variablesJson = Invoke-GitHubCli -Argument 'variable', 'list', '--repo', $repoFullName, '--json', 'name,value'
	$variables = @($variablesJson | ConvertFrom-Json | Where-Object name -in $variableNames)
	$clientIdVariable = $variables | Where-Object name -eq 'AZURE_INFRA_CLIENT_ID'
	if (-not $variables) {
		Add-Result -Area 'GitHub' -Target 'repository variables' -Action 'Delete variables' -Status 'Not found'
	}
	elseif (-not $clientIdVariable -or $clientIdVariable.value -notin $infraClientIds) {
		Write-Warning "AZURE_INFRA_CLIENT_ID does not belong to '$InfraAppDisplayName' (or that app registration is already gone). The repository variables are left untouched."
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
	}

	# Codespaces secrets of Set-CodespacesRegistrySecret.ps1
	$secretNames = 'SERVER', 'USER', 'PASSWORD' | ForEach-Object { "$($SecretPrefix)_CONTAINER_REGISTRY_$_" }
	$secretsJson = Invoke-GitHubCli -Argument 'secret', 'list', '--app', 'codespaces', '--repo', $repoFullName, '--json', 'name' -IgnoreError
	$secrets = @($secretsJson | ConvertFrom-Json | Where-Object name -in $secretNames)
	foreach ($secret in $secrets) {
		$action = 'Delete Codespaces secret'
		if ($PSCmdlet.ShouldProcess($secret.name, $action)) {
			$null = Invoke-GitHubCli -Argument 'secret', 'delete', $secret.name, '--app', 'codespaces', '--repo', $repoFullName
			Add-Result -Area 'GitHub' -Target $secret.name -Action $action -Status 'Removed'
		}
		else { Add-Result -Area 'GitHub' -Target $secret.name -Action $action -Status 'Skipped' }
	}
	if (-not $secrets) { Add-Result -Area 'GitHub' -Target "$($SecretPrefix)_CONTAINER_REGISTRY_*" -Action 'Delete Codespaces secret' -Status 'Not found' }
}
#endregion

Write-Host "`nDone. Resource provider registrations stay. On your machine: docker logout <registry>.azurecr.io"
$script:results
