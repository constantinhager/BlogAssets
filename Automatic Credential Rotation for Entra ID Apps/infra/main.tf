data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  suffix            = random_string.suffix.result
  function_location = coalesce(var.function_location, var.location)

  names = {
    resource_group   = "rg-${var.name_prefix}-${local.suffix}"
    identity         = "id-${var.name_prefix}-${local.suffix}"
    key_vault        = "kv-${var.name_prefix}-${local.suffix}"
    storage          = "st${var.name_prefix}${local.suffix}"
    log_analytics    = "log-${var.name_prefix}-${local.suffix}"
    app_insights     = "appi-${var.name_prefix}-${local.suffix}"
    service_plan     = "asp-${var.name_prefix}-${local.suffix}"
    function_app     = "func-${var.name_prefix}-${local.suffix}"
    deploy_container = "app-package"
  }

  # Built-in role definition IDs
  roles = {
    key_vault_secrets_officer      = "b86a8fe4-44ce-4948-aee5-eccb2c155cd7"
    key_vault_certificates_officer = "a4417e6f-fecd-4de8-b567-7b0420556985"
    storage_table_data_contributor = "0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3"
  }
}

resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = var.location
  tags     = var.tags
}

# ---------- Identity ----------
# User-assigned, because only a user-assigned identity can be the federated identity credential
# of the rotation app. Every Graph call goes through that app; the identity itself only gets
# Key Vault roles.
resource "azurerm_user_assigned_identity" "function" {
  name                = local.names.identity
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

# ---------- Key Vault ----------
resource "azurerm_key_vault" "this" {
  name                       = local.names.key_vault
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = var.key_vault_purge_protection
  soft_delete_retention_days = 90
  tags                       = var.tags
}

resource "azurerm_role_assignment" "function_kv_secrets" {
  scope              = azurerm_key_vault.this.id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.roles.key_vault_secrets_officer}"
  principal_id       = azurerm_user_assigned_identity.function.principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "function_kv_certificates" {
  scope              = azurerm_key_vault.this.id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.roles.key_vault_certificates_officer}"
  principal_id       = azurerm_user_assigned_identity.function.principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "admins_kv_secrets" {
  for_each           = toset(var.admin_principal_ids)
  scope              = azurerm_key_vault.this.id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.roles.key_vault_secrets_officer}"
  principal_id       = each.value
}

# ---------- Monitoring ----------
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
  application_type    = "other"
  tags                = var.tags
}

# Key Vault audit log: who read or changed which secret
resource "azurerm_monitor_diagnostic_setting" "key_vault" {
  name                       = "to-log-analytics"
  target_resource_id         = azurerm_key_vault.this.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "AuditEvent"
  }
}

# ---------- Function App (Flex Consumption) ----------
resource "azurerm_storage_account" "this" {
  name                            = local.names.storage
  location                        = local.function_location
  resource_group_name             = azurerm_resource_group.this.name
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  # Portal / Storage Explorer use Entra ID for the state table by default - so the logs show who edited a row
  default_to_oauth_authentication = true
  tags                            = var.tags
}

# ---------- Renewal state table ----------
# One row per app and credential type. Admins approve a renewal by setting RenewalState = Renewable.
resource "azurerm_storage_table" "renewals" {
  name               = var.state_table_name
  storage_account_id = azurerm_storage_account.this.id
}

# Data plane access with Entra ID, scoped to the one table - the function never uses the account key for it
resource "azurerm_role_assignment" "function_table" {
  scope              = azurerm_storage_table.renewals.id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.roles.storage_table_data_contributor}"
  principal_id       = azurerm_user_assigned_identity.function.principal_id
  principal_type     = "ServicePrincipal"
}

resource "azurerm_role_assignment" "admins_table" {
  for_each           = toset(var.admin_principal_ids)
  scope              = azurerm_storage_table.renewals.id
  role_definition_id = "/subscriptions/${data.azurerm_client_config.current.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${local.roles.storage_table_data_contributor}"
  principal_id       = each.value
}

# Audit of the approvals: StorageTableLogs record each write with the caller's object ID (Entra ID auth)
resource "azurerm_monitor_diagnostic_setting" "table" {
  name                       = "to-log-analytics"
  target_resource_id         = "${azurerm_storage_account.this.id}/tableServices/default"
  log_analytics_workspace_id = azurerm_log_analytics_workspace.this.id

  enabled_log {
    category = "StorageWrite"
  }
  enabled_log {
    category = "StorageDelete"
  }
}

resource "azurerm_storage_container" "deployment" {
  name                  = local.names.deploy_container
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

resource "azurerm_service_plan" "this" {
  name                = local.names.service_plan
  location            = local.function_location
  resource_group_name = azurerm_resource_group.this.name
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = var.tags
}

resource "azurerm_function_app_flex_consumption" "this" {
  name                        = local.names.function_app
  location                    = local.function_location
  resource_group_name         = azurerm_resource_group.this.name
  service_plan_id             = azurerm_service_plan.this.id
  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.this.primary_blob_endpoint}${azurerm_storage_container.deployment.name}"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = azurerm_storage_account.this.primary_access_key
  runtime_name                = "powershell"
  runtime_version             = var.powershell_version
  maximum_instance_count      = 40
  instance_memory_in_mb       = 2048
  https_only                  = true

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.function.id]
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.this.connection_string
    minimum_tls_version                    = "1.2"
  }

  app_settings = {
    AZURE_CLIENT_ID               = azurerm_user_assigned_identity.function.client_id
    SR_HOME_TENANT_ID             = data.azurerm_client_config.current.tenant_id
    SR_MANAGED_IDENTITY_CLIENT_ID = azurerm_user_assigned_identity.function.client_id
    SR_KEYVAULT_NAME              = azurerm_key_vault.this.name
    SR_THRESHOLD_DAYS             = tostring(var.threshold_days)
    SR_EXPIRED_GRACE_DAYS         = tostring(var.expired_grace_days)
    SR_SECRET_VALIDITY_DAYS       = tostring(var.secret_validity_days)
    SR_CERT_VALIDITY_MONTHS       = tostring(var.certificate_validity_months)
    SR_EXCLUDE_TAG                = var.exclude_tag
    SR_BACKUP_PUBLIC_CERTS        = tostring(var.backup_public_certificates)
    SR_MAIL_SENDER                = var.mail_sender
    SR_MAIL_RECIPIENTS            = join(",", var.mail_recipients)
    SR_STATE_STORAGE_ACCOUNT      = azurerm_storage_account.this.name
    SR_STATE_TABLE                = azurerm_storage_table.renewals.name
    SR_ROTATION_APP_ID            = var.rotation_app_id
    SR_CUSTOMER_TENANT_IDS        = join(",", var.customer_tenant_ids)
  }

  tags = var.tags

  lifecycle {
    # Azure adds this tag when Application Insights is linked
    ignore_changes = [tags["hidden-link: /app-insights-resource-id"]]
  }

  depends_on = [
    azurerm_role_assignment.function_kv_secrets,
    azurerm_role_assignment.function_kv_certificates,
    azurerm_role_assignment.function_table,
  ]
}
