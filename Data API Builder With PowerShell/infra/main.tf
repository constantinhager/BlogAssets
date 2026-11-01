data "azurerm_client_config" "current" {}

data "azuread_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  suffix = random_string.suffix.result

  names = {
    resource_group = "rg-${var.name_prefix}-${local.suffix}"
    log_analytics  = "log-${var.name_prefix}-${local.suffix}"
    identity       = "id-${var.name_prefix}-api-${local.suffix}"
    registry       = "acr${var.name_prefix}${local.suffix}"
    sql_server     = "sql-${var.name_prefix}-${local.suffix}"
    database       = "sqldb-meetups"
    environment    = "cae-${var.name_prefix}-${local.suffix}"
    container_app  = "ca-${var.name_prefix}-api-${local.suffix}"
  }

  tenant_id = data.azurerm_client_config.current.tenant_id
}

resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = var.location
  tags     = var.tags
}

resource "azurerm_log_analytics_workspace" "this" {
  name                = local.names.log_analytics
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

# The identity of the DAB container. Pulls the image from ACR and signs in to Azure SQL.
# User-assigned, so it exists before the container app and survives a re-creation of it.
resource "azurerm_user_assigned_identity" "dab" {
  name                = local.names.identity
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_container_registry" "this" {
  name                = local.names.registry
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Basic"
  admin_enabled       = false # no username/password - pull and push with Entra ID only
  tags                = var.tags
}

resource "azurerm_role_assignment" "dab_acr_pull" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_user_assigned_identity.dab.principal_id
  principal_type       = "ServicePrincipal"
}

# The deployment identity (GitHub Actions) pushes the image.
resource "azurerm_role_assignment" "deployer_acr_push" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPush"
  principal_id         = data.azurerm_client_config.current.object_id
}
