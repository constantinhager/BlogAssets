function Get-SrKeyVaultSecret {
	<#
	.SYNOPSIS
		Reads the current version of a Key Vault secret.

	.DESCRIPTION
		Reads the current version of a Key Vault secret.
		Returns $null if the secret doesn't exist.

	.PARAMETER Name
		Name of the secret.

	.PARAMETER MetadataOnly
		Return the secret without its value (attributes, tags, content type).

	.EXAMPLE
		PS C:\> Get-SrKeyVaultSecret -Name 'app-<appId>-secret'

		Returns the secret including its value.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]
		$Name,

		[switch]
		$MetadataOnly
	)

	$config = Get-SrConfig
	$uri = 'https://{0}.vault.azure.net/secrets/{1}?api-version={2}' -f $config.KeyVaultName, $Name, $script:KeyVaultApiVersion
	$secret = Invoke-SrRestRequest -Uri $uri -AllowNotFound
	if (-not $secret) { return $null }
	if ($MetadataOnly) { $secret.PSObject.Properties.Remove('value') }
	$secret
}
