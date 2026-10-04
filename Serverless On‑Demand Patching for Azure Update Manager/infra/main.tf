data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

resource "random_string" "suffix" {
  length  = 5
  lower   = true
  upper   = false
  numeric = true
  special = false
}

locals {
  suffix            = random_string.suffix.result
  function_location = coalesce(var.function_location, var.location)

  names = {
    resource_group  = "rg-${var.prefix}-automation"
    storage_account = "st${var.prefix}${local.suffix}"
    function_app    = "func-${var.prefix}-${local.suffix}"
    service_plan    = "asp-${var.prefix}-${local.suffix}"
    app_insights    = "appi-${var.prefix}-${local.suffix}"
    log_analytics   = "log-${var.prefix}-${local.suffix}"
    vnet            = "vnet-${var.prefix}"
    nat_gateway     = "ng-${var.prefix}"
    rdp_public_ip   = "pip-${var.prefix}-rdp"
    rdp_lb          = "lb-${var.prefix}-rdp"
    vm              = "vm-${var.prefix}-01"
  }
}

resource "azurerm_resource_group" "this" {
  name     = local.names.resource_group
  location = var.location
  tags     = var.tags
}
