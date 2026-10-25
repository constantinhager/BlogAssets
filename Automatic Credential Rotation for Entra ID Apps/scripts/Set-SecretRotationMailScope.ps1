#Requires -Modules ExchangeOnlineManagement
<#
.SYNOPSIS
	Allows the rotation app to send mail as ONE mailbox, using Exchange Online RBAC for Applications.

.DESCRIPTION
	The function sends the notification with a Graph token of the rotation app (exchanged from the managed
	identity), like every other Graph call. The Graph permission Mail.Send granted in Entra ID would allow
	the app to send as every mailbox in every tenant that consented. RBAC for Applications scopes it to a
	management scope in the home tenant instead:

	1. Register the rotation app's service principal (home tenant) in Exchange Online.
	2. Create a management scope that matches only the sender mailbox.
	3. Assign the role 'Application Mail.Send' with that scope.

	Do NOT grant Mail.Send in Entra ID in addition. Entra ID grants and RBAC grants add up - an unscoped
	Entra ID grant makes the scope useless.

	Exchange caches the permissions. A change can take 30 minutes to 2 hours to become effective.
	Test-ServicePrincipalAuthorization at the end bypasses the cache.

.PARAMETER RotationAppId
	Client (app) ID of the rotation app (output RotationAppId of New-SecretRotationApp.ps1).

.PARAMETER RotationServicePrincipalId
	Object ID of the rotation app's service principal in the home tenant (output HomeServicePrincipalId).

.PARAMETER SenderAddress
	Primary SMTP address of the mailbox the notifications come from.

.PARAMETER CreateSharedMailbox
	Create the sender as a shared mailbox (no license needed) if it doesn't exist.

.PARAMETER Organization
	The tenant, e.g. contoso.onmicrosoft.com.

.EXAMPLE
	PS C:\> ./scripts/Set-SecretRotationMailScope.ps1 -Organization contoso.onmicrosoft.com -SenderAddress secretrotation@contoso.com `
	>>   -RotationAppId $app.RotationAppId -RotationServicePrincipalId $app.HomeServicePrincipalId -CreateSharedMailbox
#>
[CmdletBinding(SupportsShouldProcess)]
param (
	[Parameter(Mandatory = $true)]
	[guid]
	$RotationAppId,

	[Parameter(Mandatory = $true)]
	[guid]
	$RotationServicePrincipalId,

	[Parameter(Mandatory = $true)]
	[string]
	$SenderAddress,

	[Parameter(Mandatory = $true)]
	[string]
	$Organization,

	[string]
	$DisplayName = 'Entra Credential Rotation',

	[string]
	$ScopeName = 'SecretRotation Sender',

	[switch]
	$CreateSharedMailbox
)

$ErrorActionPreference = 'Stop'

# A loaded assembly can't be unloaded: if another module (e.g. Az.Storage) already loaded a different
# Microsoft.OData.Core, the Exchange cmdlets fail later with a FileLoadException
$loadedOData = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'Microsoft.OData.Core' } | Select-Object -First 1
if ($loadedOData) {
	$exoModule = @(Get-Module -Name ExchangeOnlineManagement) + @(Get-Module -Name ExchangeOnlineManagement -ListAvailable | Sort-Object Version -Descending) | Select-Object -First 1
	$exoOData = Get-ChildItem -Path $exoModule.ModuleBase -Filter 'Microsoft.OData.Core.dll' -Recurse | Select-Object -First 1
	$requiredVersion = if ($exoOData) { [Reflection.AssemblyName]::GetAssemblyName($exoOData.FullName).Version }
	if ($requiredVersion -and $loadedOData.GetName().Version -ne $requiredVersion) {
		throw "This session already loaded Microsoft.OData.Core $($loadedOData.GetName().Version) from '$($loadedOData.Location)', but ExchangeOnlineManagement $($exoModule.Version) needs $requiredVersion. Run this script in a new PowerShell session."
	}
}

Connect-ExchangeOnline -Organization $Organization -ShowBanner:$false

$mailbox = Get-EXOMailbox -Identity $SenderAddress -ErrorAction SilentlyContinue
if (-not $mailbox) {
	if (-not $CreateSharedMailbox) { throw "Mailbox '$SenderAddress' not found. Use -CreateSharedMailbox to create it." }
	if ($PSCmdlet.ShouldProcess($SenderAddress, 'Create shared mailbox')) {
		$mailbox = New-Mailbox -Shared -Name $DisplayName -DisplayName $DisplayName -PrimarySmtpAddress $SenderAddress
	}
}

# 1. Service principal in Exchange Online (AppId = client ID, ObjectId = object ID of the enterprise app)
$servicePrincipal = Get-ServicePrincipal -Identity "$RotationAppId" -ErrorAction SilentlyContinue
if (-not $servicePrincipal -and $PSCmdlet.ShouldProcess($DisplayName, 'New-ServicePrincipal')) {
	$servicePrincipal = New-ServicePrincipal -AppId $RotationAppId -ObjectId $RotationServicePrincipalId -DisplayName $DisplayName
}

# 2. Management scope with exactly this mailbox
$filter = "PrimarySmtpAddress -eq '$($mailbox.PrimarySmtpAddress)'"
$scope = Get-ManagementScope -Identity $ScopeName -ErrorAction SilentlyContinue
if (-not $scope -and $PSCmdlet.ShouldProcess($ScopeName, "New-ManagementScope ($filter)")) {
	$scope = New-ManagementScope -Name $ScopeName -RecipientRestrictionFilter $filter
}

# 3. Role assignment
$assignmentName = 'SecretRotation Application Mail.Send'
$assignment = Get-ManagementRoleAssignment -Identity $assignmentName -ErrorAction SilentlyContinue
if (-not $assignment -and $PSCmdlet.ShouldProcess($DisplayName, "Assign 'Application Mail.Send' scoped to '$ScopeName'")) {
	$null = New-ManagementRoleAssignment -Name $assignmentName -App "$RotationAppId" -Role 'Application Mail.Send' -CustomResourceScope $ScopeName
}

# Check (bypasses the permission cache): InScope must be True for the sender mailbox
Test-ServicePrincipalAuthorization -Identity "$RotationAppId" -Resource $SenderAddress |
	Format-Table RoleName, GrantedPermissions, AllowedResourceScope, InScope
