# Module-wide constants. Loaded by SecretRotation.psm1 after the functions.

# Azure Key Vault data plane API version
$script:KeyVaultApiVersion = '2025-07-01'

# Display name prefix of every credential this function creates in Entra ID.
# Used to recognize our own credentials (e.g. to skip them in the public certificate backup).
$script:CredentialDisplayNamePrefix = 'SecretRotation'
