data "azurerm_client_config" "current" {}

resource "random_string" "suffix" {
  length  = 5
  upper   = false
  special = false
}

locals {
  suffix        = random_string.suffix.result
  func_name     = "func-${var.prefix}-${local.suffix}"
  sql_conn      = "Server=tcp:${azurerm_mssql_server.sql.fully_qualified_domain_name},1433;Database=${azurerm_mssql_database.db.name};Authentication=Active Directory Managed Identity;User Id=${azurerm_user_assigned_identity.sql.client_id};Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;"
  deploy_ctr    = "app-package"
  function_name = "Import-CsvBlob" # = PS function in BlobToSql/functions/blobTrigger (build creates a folder with this name)

  # SQL admin: an Entra group (recommended: you + the CI service principal) or, if not set, whoever runs Terraform
  sql_admin_object_id = coalesce(var.sql_admin_object_id, data.azurerm_client_config.current.object_id)
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-${var.prefix}-${local.suffix}"
  location = var.location
  tags     = var.tags
}

# ---------------------------------------------------------------------------
# Monitoring
# ---------------------------------------------------------------------------
resource "azurerm_log_analytics_workspace" "law" {
  name                = "log-${var.prefix}-${local.suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = var.tags
}

resource "azurerm_application_insights" "appi" {
  name                = "appi-${var.prefix}-${local.suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  workspace_id        = azurerm_log_analytics_workspace.law.id
  application_type    = "web"
  tags                = var.tags
}

# ---------------------------------------------------------------------------
# Storage 1: function host (AzureWebJobsStorage + deployment package)
# ---------------------------------------------------------------------------
resource "azurerm_storage_account" "host" {
  name                            = "st${var.prefix}fn${local.suffix}"
  location                        = azurerm_resource_group.rg.location
  resource_group_name             = azurerm_resource_group.rg.name
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  tags                            = var.tags
}

resource "azurerm_storage_container" "deploy" {
  name                  = local.deploy_ctr
  storage_account_id    = azurerm_storage_account.host.id
  container_access_type = "private"
}

# ---------------------------------------------------------------------------
# Storage 2: data (the .txt files land here)
# ---------------------------------------------------------------------------
resource "azurerm_storage_account" "data" {
  name                            = "st${var.prefix}dt${local.suffix}"
  location                        = azurerm_resource_group.rg.location
  resource_group_name             = azurerm_resource_group.rg.name
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  tags                            = var.tags
}

resource "azurerm_storage_container" "incoming" {
  name                  = var.input_container_name
  storage_account_id    = azurerm_storage_account.data.id
  container_access_type = "private"
}

# ---------------------------------------------------------------------------
# Function App (Flex Consumption, PowerShell, system-assigned identity)
# ---------------------------------------------------------------------------
# SQL identity. User-assigned, because its client ID is known to Terraform:
# the database user is created WITH SID = <client id>, TYPE = E. That needs no Graph lookup,
# so the CI service principal can create it without Directory Readers on the SQL server.
resource "azurerm_user_assigned_identity" "sql" {
  name                = "id-${var.prefix}-sql-${local.suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  tags                = var.tags
}

resource "azurerm_service_plan" "plan" {
  name                = "asp-${var.prefix}-${local.suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  os_type             = "Linux"
  sku_name            = "FC1"
  tags                = var.tags
}

resource "azurerm_function_app_flex_consumption" "func" {
  name                = local.func_name
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  service_plan_id     = azurerm_service_plan.plan.id

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "${azurerm_storage_account.host.primary_blob_endpoint}${local.deploy_ctr}"
  storage_authentication_type = "SystemAssignedIdentity"

  runtime_name           = "powershell"
  runtime_version        = var.powershell_version
  maximum_instance_count = 40
  instance_memory_in_mb  = 2048
  https_only             = true

  webdeploy_publish_basic_authentication_enabled = false

  # System-assigned: storage (host + trigger). User-assigned: SQL only.
  identity {
    type         = "SystemAssigned, UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.sql.id]
  }

  site_config {
    application_insights_connection_string = azurerm_application_insights.appi.connection_string
  }

  app_settings = {
    # Workaround: with SystemAssignedIdentity the provider still writes a key-based
    # AzureWebJobsStorage value (empty key). Blank it so the __accountName form is used.
    # Same workaround as Microsoft's Flex Terraform sample.
    "AzureWebJobsStorage"              = ""
    "AzureWebJobsStorage__accountName" = azurerm_storage_account.host.name

    # Identity-based connection for the blob trigger ("connection": "DataStorage").
    # queueServiceUri is required for blob triggers (poison-blob queue).
    "DataStorage__blobServiceUri"  = azurerm_storage_account.data.primary_blob_endpoint
    "DataStorage__queueServiceUri" = azurerm_storage_account.data.primary_queue_endpoint

    # SQL output binding, authenticates with the app's system-assigned identity.
    "SqlConnectionString" = local.sql_conn

    # Parsing options read by Import-CsvBlob
    "CSV_FILE_EXTENSIONS" = join(",", var.file_extensions)
    "CSV_DELIMITER"       = var.csv_delimiter
    "CSV_ENCODING"        = var.csv_encoding
    "CSV_SOURCE_TIMEZONE" = var.csv_source_timezone
  }

  tags = var.tags
}

# Host storage: deployment package + runtime state
resource "azurerm_role_assignment" "func_host_blob" {
  scope                = azurerm_storage_account.host.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_function_app_flex_consumption.func.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Data storage: blob trigger reads blobs, writes poison messages to a queue
resource "azurerm_role_assignment" "func_data_blob" {
  scope                = azurerm_storage_account.data.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_function_app_flex_consumption.func.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_role_assignment" "func_data_queue" {
  scope                = azurerm_storage_account.data.id
  role_definition_name = "Storage Queue Data Contributor"
  principal_id         = azurerm_function_app_flex_consumption.func.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}

# Lets the admins upload test files with --auth-mode login
resource "azurerm_role_assignment" "admins_data_blob" {
  scope                = azurerm_storage_account.data.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = local.sql_admin_object_id
}

# ---------------------------------------------------------------------------
# Azure SQL (Entra-only auth)
# ---------------------------------------------------------------------------
resource "azurerm_mssql_server" "sql" {
  name                = "sql-${var.prefix}-${local.suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  version             = "12.0"
  minimum_tls_version = "1.2"

  azuread_administrator {
    login_username              = var.sql_admin_login_name
    object_id                   = local.sql_admin_object_id
    tenant_id                   = data.azurerm_client_config.current.tenant_id
    azuread_authentication_only = true
  }

  tags = var.tags
}

resource "azurerm_mssql_database" "db" {
  name        = "sqldb-${var.prefix}"
  server_id   = azurerm_mssql_server.sql.id
  sku_name    = var.sql_database_sku
  max_size_gb = 2
  tags        = var.tags
}

# Flex Consumption without VNet integration has no fixed outbound IPs.
# For production: VNet integration + private endpoint, then drop this rule.
resource "azurerm_mssql_firewall_rule" "azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_mssql_server.sql.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_mssql_firewall_rule" "client" {
  count            = var.client_ip_address == null ? 0 : 1
  name             = "ClientIp"
  server_id        = azurerm_mssql_server.sql.id
  start_ip_address = var.client_ip_address
  end_ip_address   = var.client_ip_address
}

# ---------------------------------------------------------------------------
# Event Grid: BlobCreated (CSV files in the input container) -> blob extension webhook
# Flex Consumption only supports the Event Grid-based blob trigger.
# ---------------------------------------------------------------------------
resource "azurerm_eventgrid_system_topic" "data" {
  name                = "evgt-${var.prefix}-${local.suffix}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  source_resource_id  = azurerm_storage_account.data.id
  topic_type          = "Microsoft.Storage.StorageAccounts"
  tags                = var.tags
}

data "azurerm_function_app_host_keys" "func" {
  count               = var.enable_event_subscription ? 1 : 0
  name                = azurerm_function_app_flex_consumption.func.name
  resource_group_name = azurerm_resource_group.rg.name
}

resource "azurerm_eventgrid_system_topic_event_subscription" "txt_created" {
  count               = var.enable_event_subscription ? 1 : 0
  name                = "txt-created-to-func"
  system_topic        = azurerm_eventgrid_system_topic.data.name
  resource_group_name = azurerm_resource_group.rg.name

  event_delivery_schema = "EventGridSchema"
  included_event_types  = ["Microsoft.Storage.BlobCreated"]

  subject_filter {
    subject_begins_with = "/blobServices/default/containers/${var.input_container_name}/blobs/"
    case_sensitive      = false
  }

  # advanced_filter is a single block (max 1); its conditions are ANDed.
  advanced_filter {
    # subject_ends_with takes one value only; string_ends_with takes a list (case-insensitive)
    string_ends_with {
      key    = "subject"
      values = var.file_extensions
    }

    # Only fire when the blob is fully committed
    string_in {
      key    = "data.api"
      values = ["PutBlob", "PutBlockList", "FlushWithClose", "CopyBlob"]
    }
  }

  webhook_endpoint {
    url = "https://${azurerm_function_app_flex_consumption.func.default_hostname}/runtime/webhooks/blobs?functionName=Host.Functions.${local.function_name}&code=${data.azurerm_function_app_host_keys.func[0].blobs_extension_key}"
  }

  retry_policy {
    max_delivery_attempts = 30
    event_time_to_live    = 1440
  }
}
