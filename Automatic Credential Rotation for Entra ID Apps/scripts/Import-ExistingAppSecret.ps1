#Requires -Modules Az.Accounts, Az.KeyVault, Microsoft.Graph.Applications
<#
.SYNOPSIS
	Stores an existing client secret of an app in the Key Vault - if you still have its value.

.DESCRIPTION
	Entra ID never returns the value of a client secret after it was created. The function can't
	back up existing secrets for that reason. If someone still has the value (password manager,
	old pipeline variable), this script brings it into the same structure the function uses:

	1. Ask for the secret as SecureString (nothing on the command line or in the history).
	2. Prove the value works: request a token with client_credentials for this app.
	3. Find the matching credential on the app by its hint (first three characters) to get keyId and expiry.
	4. Store it as a version of app-<appId>-secret, with the same tags the function writes.

	If the current version in Key Vault lives longer than the imported secret, the script stops -
	otherwise the import would replace a newer secret as "current" version. Use -Force to import anyway.

.PARAMETER AppId
	Application (client) ID.

.PARAMETER TenantId
	Tenant of the app.

.PARAMETER KeyVaultName
	The Key Vault of the rotation function.

.PARAMETER Force
	Import even if Key Vault already has a secret that lives longer.

.EXAMPLE
	PS C:\> ./scripts/Import-ExistingAppSecret.ps1 -AppId $appId -TenantId $tenantId -KeyVaultName kv-secrot-ab12c
#>
[CmdletBinding(SupportsShouldProcess)]
param (
	[Parameter(Mandatory = $true)]
	[guid]
	$AppId,

	[Parameter(Mandatory = $true)]
	[guid]
	$TenantId,

	[Parameter(Mandatory = $true)]
	[string]
	$KeyVaultName,

	[switch]
	$Force
)

$ErrorActionPreference = 'Stop'
$secret = Read-Host -Prompt "Client secret of app $AppId" -AsSecureString
$plain = [System.Net.NetworkCredential]::new('', $secret).Password

# 2. Does the value work?
try {
	$null = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" -Body @{
		client_id     = "$AppId"
		client_secret = $plain
		scope         = 'https://graph.microsoft.com/.default'
		grant_type    = 'client_credentials'
	}
}
catch {
	throw "The secret doesn't work for app $AppId (token request failed): $($_.ErrorDetails.Message)"
}

# 3. Which credential is it?
Connect-MgGraph -TenantId $TenantId -Scopes 'Application.Read.All' -NoWelcome
$app = Get-MgApplication -Filter "appId eq '$AppId'" -Property id, appId, displayName, passwordCredentials
$candidates = @($app.PasswordCredentials | Where-Object { $plain.StartsWith($_.Hint) -and $_.EndDateTime -gt (Get-Date).ToUniversalTime() })
if ($candidates.Count -ne 1) {
	throw "Found $($candidates.Count) valid secrets with hint '$($plain.Substring(0,3))' on the app - can't tell which one it is."
}
$credential = $candidates[0]

# 4. Store it
$name = "app-$AppId-secret"
Connect-AzAccount -Tenant $TenantId -ErrorAction Stop | Out-Null
$current = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $name -ErrorAction SilentlyContinue
if ($current -and $current.Expires -and $current.Expires -gt $credential.EndDateTime -and -not $Force) {
	throw "Key Vault already holds a secret valid until $($current.Expires.ToString('yyyy-MM-dd')). The imported one expires $($credential.EndDateTime.ToString('yyyy-MM-dd')). Use -Force to import anyway."
}

if ($PSCmdlet.ShouldProcess("$KeyVaultName/$name", "Import secret $($credential.KeyId)")) {
	$tags = @{
		appId          = "$AppId"
		appObjectId    = $app.Id
		appDisplayName = $app.DisplayName
		tenantId       = "$TenantId"
		keyId          = "$($credential.KeyId)"
		credentialType = 'ClientSecret'
		createdBy      = 'Import-ExistingAppSecret'
	}
	$null = Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $name -SecretValue $secret -ContentType 'text/plain' `
		-NotBefore $credential.StartDateTime -Expires $credential.EndDateTime -Tag $tags
	Write-Host "Stored secret $($credential.KeyId) of '$($app.DisplayName)' as $name (expires $($credential.EndDateTime.ToString('yyyy-MM-dd')))."
}
$plain = $null
