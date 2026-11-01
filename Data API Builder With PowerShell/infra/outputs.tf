output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "container_app_name" {
  value = azurerm_container_app.dab.name
}

output "api_url" {
  value = "https://${azurerm_container_app.dab.ingress[0].fqdn}"
}

output "acr_name" {
  value = azurerm_container_registry.this.name
}

output "acr_login_server" {
  value = azurerm_container_registry.this.login_server
}

output "sql_server_name" {
  value = azurerm_mssql_server.this.name
}

output "sql_server_fqdn" {
  value = azurerm_mssql_server.this.fully_qualified_domain_name
}

output "database_name" {
  value = azurerm_mssql_database.this.name
}

output "dab_identity_name" {
  value = azurerm_user_assigned_identity.dab.name
}

output "dab_identity_client_id" {
  value = azurerm_user_assigned_identity.dab.client_id
}

output "api_client_id" {
  value = azuread_application.api.client_id
}

output "api_identifier_uri" {
  value = azuread_application_identifier_uri.api.identifier_uri
}

output "tenant_id" {
  value = local.tenant_id
}
