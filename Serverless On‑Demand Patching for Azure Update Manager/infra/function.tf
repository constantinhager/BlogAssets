resource "azurerm_log_analytics_workspace" "this" {
  name                = local.names.log_analytics
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_application_insights" "this" {
  name                = local.names.app_insights
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  workspace_id        = azurerm_log_analytics_workspace.this.id
  application_type    = "web"
  tags                = var.tags
}

resource "azurerm_service_plan" "this" {
  name                = local.names.service_plan
  location            = local.function_location
  resource_group_name = azurerm_resource_group.this.name
  os_type             = "Linux"
  sku_name            = "FC1" # Flex Consumption
  tags                = var.tags
}

resource "azurerm_function_app_flex_consumption" "this" {
  name                = local.names.function_app
  location            = local.function_location
  resource_group_name = azurerm_resource_group.this.name
  service_plan_id     = azurerm_service_plan.this.id
  https_only          = true

  # Deployment package storage (Flex Consumption)
  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.this.primary_blob_endpoint}${azurerm_storage_container.deployment.name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.this.primary_access_key

  runtime_name           = "powershell"
  runtime_version        = var.powershell_version
  instance_memory_in_mb  = 2048
  maximum_instance_count = var.function_maximum_instance_count

  identity {
    type = "SystemAssigned"
  }

  # Read by Get-AumConfig in the PowerShell module
  app_settings = {
    AUM_SUBSCRIPTION_IDS          = data.azurerm_subscription.current.subscription_id
    AUM_DEFAULT_LOCATION          = var.location
    AUM_MAINTENANCE_RG            = azurerm_resource_group.this.name
    AUM_EXCLUSION_STORAGE_ACCOUNT = azurerm_storage_account.this.name
    AUM_EXCLUSION_TABLE           = azurerm_storage_table.exclusions.name
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.this.connection_string
    minimum_tls_version                    = "1.2"
  }

  tags = var.tags
}
