# Azure SQL with Microsoft Entra authentication only. There is no SQL login and no password.
# The Entra admin is a group: the GitHub Actions identity (to deploy schema and users)
# plus the humans who need admin access.
#
# The server has no managed identity and no Directory Readers role. That is on purpose:
# the database user for DAB is created with an explicit SID (database/Scripts/DabUser.sql),
# so the server never has to look anything up in Microsoft Graph.
resource "azurerm_mssql_server" "this" {
  name                          = local.names.sql_server
  location                      = azurerm_resource_group.this.location
  resource_group_name           = azurerm_resource_group.this.name
  version                       = "12.0"
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true

  azuread_administrator {
    login_username              = var.sql_admin_group_name
    object_id                   = var.sql_admin_group_object_id
    tenant_id                   = local.tenant_id
    azuread_authentication_only = true
  }

  tags = var.tags
}

# "Allow Azure services and resources to access this server".
# The Consumption container app has no fixed outbound IP. See the post for the private alternative.
resource "azurerm_mssql_firewall_rule" "azure_services" {
  name             = "AllowAllWindowsAzureIps"
  server_id        = azurerm_mssql_server.this.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

# Terraform owns the database itself (SKU, size, backup redundancy).
# The schema comes from the SQL database project (database/MeetupDb.sqlproj) via SqlPackage.
resource "azurerm_mssql_database" "this" {
  name                 = local.names.database
  server_id            = azurerm_mssql_server.this.id
  sku_name             = var.sql_sku_name
  max_size_gb          = var.sql_max_size_gb
  storage_account_type = "Local"
  tags                 = var.tags
}
