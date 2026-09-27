@{
	# Do you really need ALL of the AZ modules?
	# Az = '1.*'

	# If you only need Key Vault access, this is your choice
	# 'Az.KeyVault' = '4.*'

	# Basic tools used in your function app
	# Only needed by the http/eventGrid trigger wrappers (Get-RestParameter, Write-FunctionResult).
	# The blob trigger does not use it, so it stays disabled to keep the package small.
	# 'Azure.Function.Tools' = '1.*'
}