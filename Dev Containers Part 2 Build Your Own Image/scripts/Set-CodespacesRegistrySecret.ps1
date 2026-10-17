<#
.SYNOPSIS
	Gives GitHub Codespaces pull access to the dev container image in Azure Container Registry.

.DESCRIPTION
	GitHub Codespaces can't sign in to a registry with Entra ID. It reads three Codespaces secrets
	instead and runs 'docker login' with them before it pulls the image:

	  <PREFIX>_CONTAINER_REGISTRY_SERVER     e.g. acrdevcontainerx1y2z3.azurecr.io
	  <PREFIX>_CONTAINER_REGISTRY_USER       the name of the ACR token
	  <PREFIX>_CONTAINER_REGISTRY_PASSWORD   a password of the ACR token

	Terraform creates the token (codespaces-pull) with a scope map that can only read the image
	repository - but without a password, so the password never lands in the Terraform state.
	This script generates a password with an expiry date (New-AzContainerRegistryCredentials) and writes
	the three secrets as repository-level Codespaces secrets (gh secret set --app codespaces).

	An ACR token has two passwords. Rotate without downtime by switching between them:
	run with -PasswordName password2 before password1 expires, and the other way round next time.

	Needs the Az PowerShell modules Az.Accounts and Az.ContainerRegistry (signed in with Connect-AzAccount,
	rights to generate token credentials on the registry, e.g. Contributor) and the GitHub CLI
	(signed in with 'gh auth login', admin on the repository). All of them are in the DevOps dev container image.

.PARAMETER RegistryName
	Name of the container registry (without .azurecr.io).

.PARAMETER ResourceGroupName
	Resource group of the registry. Looked up by the registry name when not given.

.PARAMETER GitHubRepository
	Repository in the form <owner>/<name>. The secrets are created on this repository.

.PARAMETER TokenName
	Name of the ACR token created by Terraform.

.PARAMETER PasswordName
	Which of the two token passwords to (re)generate.

.PARAMETER ExpirationInDays
	Lifetime of the password.

.PARAMETER SecretPrefix
	Prefix of the three Codespaces secrets.

.EXAMPLE
	PS C:\> Connect-AzAccount
	PS C:\> gh auth login
	PS C:\> $secret = @{
		RegistryName     = 'acrdevcontainerx1y2z3'
		GitHubRepository = 'contoso/BlogAssets'
	}
	PS C:\> ./Set-CodespacesRegistrySecret.ps1 @secret

	Generates password1 (valid for 90 days) and writes the three Codespaces secrets.

.EXAMPLE
	PS C:\> $secret = @{
		RegistryName     = 'acrdevcontainerx1y2z3'
		GitHubRepository = 'contoso/BlogAssets'
		PasswordName     = 'password2'
		ExpirationInDays = 30
	}
	PS C:\> ./Set-CodespacesRegistrySecret.ps1 @secret

	Rotation: generates password2 and replaces the secret. password1 keeps working until it expires.
#>
#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.ContainerRegistry
[CmdletBinding(SupportsShouldProcess)]
param (
	[Parameter(Mandatory)]
	[ValidatePattern('^[a-zA-Z0-9]{5,50}$', ErrorMessage = "'{0}' is not a valid registry name.")]
	[string]
	$RegistryName,

	[Parameter()]
	[ValidateLength(1, 90)]
	[string]
	$ResourceGroupName,

	[Parameter(Mandatory)]
	[ValidatePattern('^[A-Za-z0-9-]{1,39}/[A-Za-z0-9._-]{1,100}$', ErrorMessage = "'{0}' is not in the form <owner>/<repository>.")]
	[string]
	$GitHubRepository,

	[Parameter()]
	[ValidateNotNullOrEmpty()]
	[string]
	$TokenName = 'codespaces-pull',

	[Parameter()]
	[ValidateSet('password1', 'password2')]
	[string]
	$PasswordName = 'password1',

	[Parameter()]
	[ValidateRange(1, 365)]
	[int]
	$ExpirationInDays = 90,

	[Parameter()]
	[ValidatePattern('^[A-Z][A-Z0-9_]*$', ErrorMessage = "'{0}' must be upper case letters, digits and underscores.")]
	[string]
	$SecretPrefix = 'ACR'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-AzContext)) { throw "Not signed in. Run 'Connect-AzAccount' first." }
if (-not (Get-Command gh -ErrorAction Ignore)) { throw 'GitHub CLI (gh) not found. Run this script in the dev container or install it.' }

if (-not $ResourceGroupName) {
	$registryResource = Get-AzResource -Name $RegistryName -ResourceType 'Microsoft.ContainerRegistry/registries' | Select-Object -First 1
	if (-not $registryResource) { throw "Registry '$RegistryName' not found in subscription '$((Get-AzContext).Subscription.Name)'." }
	$ResourceGroupName = $registryResource.ResourceGroupName
}
$registry = Get-AzContainerRegistry -ResourceGroupName $ResourceGroupName -Name $RegistryName
$server = $registry.LoginServer
$token = Get-AzContainerRegistryToken -RegistryName $RegistryName -ResourceGroupName $ResourceGroupName -Name $TokenName

if (-not $PSCmdlet.ShouldProcess("$server, token $TokenName", "Generate $PasswordName (valid $ExpirationInDays days) and write Codespaces secrets to $GitHubRepository")) {
	return
}

# -Name selects the slot (password1 / password2). The result contains the user name and the new password.
$generate = @{
	RegistryName      = $RegistryName
	ResourceGroupName = $ResourceGroupName
	TokenId           = $token.Id
	Name              = $PasswordName
	Expiry            = (Get-Date).ToUniversalTime().AddDays($ExpirationInDays)
}
$credential = New-AzContainerRegistryCredentials @generate

# Only the generated password comes back - match by name, fall back to the first one
$password = $credential.Password | Where-Object Name -eq $PasswordName | Select-Object -First 1
if (-not $password) { $password = $credential.Password | Select-Object -First 1 }
$passwordValue = $password.Value
if ($passwordValue -is [securestring]) { $passwordValue = $passwordValue | ConvertFrom-SecureString -AsPlainText }
if (-not $passwordValue) { throw "No password returned for token '$TokenName'." }

$secrets = [ordered]@{
	"$($SecretPrefix)_CONTAINER_REGISTRY_SERVER"   = $server
	"$($SecretPrefix)_CONTAINER_REGISTRY_USER"     = $credential.Username
	"$($SecretPrefix)_CONTAINER_REGISTRY_PASSWORD" = $passwordValue
}

foreach ($entry in $secrets.GetEnumerator()) {
	# The value goes through stdin, not the command line. gh encrypts it before the upload.
	$entry.Value | gh secret set $entry.Key --app codespaces --repo $GitHubRepository
	if ($LASTEXITCODE -ne 0) { throw "Could not set the Codespaces secret $($entry.Key) on $GitHubRepository." }
	Write-Host "[ok] Codespaces secret $($entry.Key)"
}

[pscustomobject]@{
	Server     = $server
	User       = $credential.Username
	Password   = $PasswordName
	Expires    = $password.Expiry
	Repository = $GitHubRepository
}
Write-Host "Running codespaces need a restart to see the new secrets."
