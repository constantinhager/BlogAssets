output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "function_app_name" {
  value = azurerm_function_app_flex_consumption.this.name
}

output "key_vault_name" {
  value = azurerm_key_vault.this.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.this.vault_uri
}

output "managed_identity_name" {
  value = azurerm_user_assigned_identity.function.name
}

output "managed_identity_client_id" {
  description = "Client ID (app ID) of the managed identity."
  value       = azurerm_user_assigned_identity.function.client_id
}

output "managed_identity_principal_id" {
  description = "Object (principal) ID of the managed identity - subject of the rotation app's federated identity credential."
  value       = azurerm_user_assigned_identity.function.principal_id
}

output "tenant_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "state_storage_account" {
  description = "Storage account of the renewal state table."
  value       = azurerm_storage_account.this.name
}

output "state_table" {
  description = "Renewal state table - set RenewalState = Renewable to approve a renewal."
  value       = azurerm_storage_table.renewals.name
}
