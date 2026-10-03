# One storage account for:
# - the Function App host storage (AzureWebJobsStorage) and the Flex Consumption deployment container
# - the exclusion table (KBs that must not be installed)
#
# The Function code reads the table with its Managed Identity (RBAC), not with the account key.

resource "azurerm_storage_account" "this" {
  name                            = local.names.storage_account
  location                        = azurerm_resource_group.this.location
  resource_group_name             = azurerm_resource_group.this.name
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  https_traffic_only_enabled      = true
  tags                            = var.tags
}

# Flex Consumption: the deployment package (Function.zip) is stored here
resource "azurerm_storage_container" "deployment" {
  name                  = "app-package"
  storage_account_id    = azurerm_storage_account.this.id
  container_access_type = "private"
}

resource "azurerm_storage_table" "exclusions" {
  name               = var.exclusion_table_name
  storage_account_id = azurerm_storage_account.this.id
}

# Seed rows. Manage further rows in the portal (Storage browser), Azure Storage Explorer or via REST.
resource "azurerm_storage_table_entity" "exclusion" {
  for_each = var.sample_exclusions

  storage_table_id = azurerm_storage_table.exclusions.id
  partition_key    = split("/", each.key)[0]
  row_key          = split("/", each.key)[1]

  entity = {
    Title   = each.value.title
    Reason  = each.value.reason
    Enabled = "true"
  }
}
