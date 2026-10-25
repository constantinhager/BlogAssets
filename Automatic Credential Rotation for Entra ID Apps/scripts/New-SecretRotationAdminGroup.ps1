#Requires -Modules Microsoft.Graph.Groups, Microsoft.Graph.Users
<#
.SYNOPSIS
	Creates the security group of the approvers - the group behind the Terraform variable admin_principal_ids.

.DESCRIPTION
	Members of this group approve renewals. Terraform gives the group
	- Storage Table Data Contributor on the renewal state table (set RenewalState = Renewable)
	- Key Vault Secrets Officer on the Key Vault (import existing secrets)

	The script:
	1. creates a cloud-only security group (not mail-enabled), or reuses it if it exists
	2. adds the owners and members you pass (UPNs or object IDs) - existing ones are kept
	3. prints the group's object ID, and with -TfvarsPath writes it into production.tfvars

	Membership is the approval right. Keep the group small. For production, consider making the group
	eligible-only with Privileged Identity Management for Groups, so approvers activate membership just in time.

	Needs a Groups Administrator (or a user who may create security groups) and the Graph scopes
	Group.ReadWrite.All and User.Read.All.

.PARAMETER TenantId
	The home tenant.

.PARAMETER DisplayName
	Display name of the group.

.PARAMETER Member
	UPNs or object IDs of the approvers.

.PARAMETER Owner
	UPNs or object IDs of the group owners (they manage membership).

.PARAMETER TfvarsPath
	Path to production.tfvars. If set, the line 'admin_principal_ids = [...]' is replaced (or added) with the group's object ID.

.EXAMPLE
	PS C:\> ./scripts/New-SecretRotationAdminGroup.ps1 -TenantId $tenantId -Member alice@contoso.com, bob@contoso.com -Owner alice@contoso.com -TfvarsPath ./infra/production.tfvars
#>
[CmdletBinding(SupportsShouldProcess)]
param (
	[Parameter(Mandatory = $true)]
	[guid]
	$TenantId,

	[string]
	$DisplayName = 'SG-SecretRotation-Approvers',

	[string[]]
	$Member = @(),

	[string[]]
	$Owner = @(),

	[string]
	$TfvarsPath
)

$ErrorActionPreference = 'Stop'
Connect-MgGraph -TenantId $TenantId -Scopes 'Group.ReadWrite.All', 'User.Read.All' -NoWelcome

function Resolve-DirectoryUser {
	param ([string]$Identity)
	$guid = [guid]::Empty
	if ([guid]::TryParse($Identity, [ref]$guid)) { return (Get-MgUser -UserId $Identity).Id }
	$user = Get-MgUser -Filter "userPrincipalName eq '$($Identity.Replace("'", "''"))'"
	if (-not $user) { throw "User '$Identity' not found." }
	$user.Id
}

# 1. Group
$group = @(Get-MgGroup -Filter "displayName eq '$($DisplayName.Replace("'", "''"))'")
if ($group.Count -gt 1) { throw "More than one group named '$DisplayName'." }
$group = $group | Select-Object -First 1
if (-not $group -and $PSCmdlet.ShouldProcess($DisplayName, 'Create security group')) {
	$nickname = ($DisplayName -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
	$group = New-MgGroup -DisplayName $DisplayName -MailEnabled:$false -MailNickname $nickname -SecurityEnabled:$true `
		-Description 'Approvers of Entra ID app credential renewals: may set RenewalState = Renewable in the renewal state table.'
	Write-Host "Created group $DisplayName ($($group.Id))."
}
elseif ($group) {
	Write-Host "Group $DisplayName exists ($($group.Id))."
}

# 2. Owners and members
if ($group) {
	$currentOwners = @(Get-MgGroupOwner -GroupId $group.Id -All | ForEach-Object Id)
	foreach ($identity in $Owner) {
		$id = Resolve-DirectoryUser -Identity $identity
		if ($id -in $currentOwners) { continue }
		if ($PSCmdlet.ShouldProcess($identity, "Add owner of $DisplayName")) {
			New-MgGroupOwnerByRef -GroupId $group.Id -OdataId "https://graph.microsoft.com/v1.0/directoryObjects/$id"
		}
	}

	$currentMembers = @(Get-MgGroupMember -GroupId $group.Id -All | ForEach-Object Id)
	foreach ($identity in $Member) {
		$id = Resolve-DirectoryUser -Identity $identity
		if ($id -in $currentMembers) { continue }
		if ($PSCmdlet.ShouldProcess($identity, "Add member of $DisplayName")) {
			New-MgGroupMemberByRef -GroupId $group.Id -OdataId "https://graph.microsoft.com/v1.0/directoryObjects/$id"
		}
	}
}

# 3. Terraform variable
$line = 'admin_principal_ids = ["{0}"]' -f $group.Id
if ($TfvarsPath -and $group) {
	if (-not (Test-Path $TfvarsPath)) { throw "'$TfvarsPath' not found. Copy production.tfvars.example first." }
	$content = Get-Content -Path $TfvarsPath -Raw
	if ($content -match '(?m)^\s*admin_principal_ids\s*=.*$') { $content = $content -replace '(?m)^\s*admin_principal_ids\s*=.*$', $line }
	else { $content = $content.TrimEnd() + "`n`n$line`n" }
	if ($PSCmdlet.ShouldProcess($TfvarsPath, $line)) { Set-Content -Path $TfvarsPath -Value $content -NoNewline }
}

[pscustomobject]@{
	GroupName = $DisplayName
	GroupId   = $group.Id
	Tfvars    = $line
}
