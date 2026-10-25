function Set-SrKeyVaultSecret {
	<#
	.SYNOPSIS
		Writes a secret (new version) to the Key Vault.

	.PARAMETER Name
		Name of the secret.

	.PARAMETER Value
		The secret value.

	.PARAMETER ContentType
		Content type of the value, e.g. 'text/plain' or 'application/pkix-cert'.

	.PARAMETER NotBefore
		Activation date (nbf) of the secret.

	.PARAMETER Expires
		Expiration date (exp) of the secret.

	.PARAMETER Tags
		Tags of this secret version (max. 15, values max. 256 characters).

	.EXAMPLE
		PS C:\> Set-SrKeyVaultSecret -Name 'app-...-secret' -Value $secretText -Expires $end

		Creates a new version of the secret.
	#>
	[CmdletBinding()]
	param (
		[Parameter(Mandatory = $true)]
		[string]
		$Name,

		[Parameter(Mandatory = $true)]
		[string]
		$Value,

		[string]
		$ContentType = 'text/plain',

		[Nullable[DateTimeOffset]]
		$NotBefore,

		[Nullable[DateTimeOffset]]
		$Expires,

		[hashtable]
		$Tags = @{}
	)

	$config = Get-SrConfig
	$attributes = @{ enabled = $true }
	if ($NotBefore) { $attributes.nbf = ([DateTimeOffset]$NotBefore).ToUnixTimeSeconds() }
	if ($Expires) { $attributes.exp = ([DateTimeOffset]$Expires).ToUnixTimeSeconds() }

	$body = @{
		value       = $Value
		contentType = $ContentType
		attributes  = $attributes
		tags        = ConvertTo-SrVaultTag -Tags $Tags
	}
	$uri = 'https://{0}.vault.azure.net/secrets/{1}?api-version={2}' -f $config.KeyVaultName, $Name, $script:KeyVaultApiVersion
	$result = Invoke-SrRestRequest -Method PUT -Uri $uri -Body $body

	# Never hand the value back to the caller - it would end up in logs
	[pscustomobject]@{
		Id   = $result.id
		Name = $Name
	}
}
