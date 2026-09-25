output "resource_group" {
  value = azurerm_resource_group.rg.name
}

output "function_app_name" {
  value = azurerm_function_app_flex_consumption.func.name
}

output "function_principal_id" {
  value = azurerm_function_app_flex_consumption.func.identity[0].principal_id
}

output "data_storage_account" {
  value = azurerm_storage_account.data.name
}

output "input_container" {
  value = azurerm_storage_container.incoming.name
}

output "sql_server_fqdn" {
  value = azurerm_mssql_server.sql.fully_qualified_domain_name
}

output "sql_database" {
  value = azurerm_mssql_database.db.name
}

output "sql_identity_name" {
  value = azurerm_user_assigned_identity.sql.name
}

output "sql_identity_client_id" {
  value = azurerm_user_assigned_identity.sql.client_id
}
