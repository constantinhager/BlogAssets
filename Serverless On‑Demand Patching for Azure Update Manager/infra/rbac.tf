# Least-privilege custom role for the Function App's Managed Identity.
# Actions taken from "Azure Update Manager - roles and permissions" (Microsoft Learn).
resource "azurerm_role_definition" "update_manager_operator" {
  name        = "Update Manager Automation Operator (${local.suffix})"
  scope       = data.azurerm_subscription.current.id
  description = "Trigger assessments and one-time updates, manage maintenance configurations. Used by ${local.names.function_app}."

  permissions {
    actions = [
      # Discovery (Azure Resource Graph only returns what the identity can read)
      "Microsoft.Resources/subscriptions/resourceGroups/read",
      "Microsoft.Compute/virtualMachines/read",
      "Microsoft.HybridCompute/machines/read",

      # On-demand assessment + one-time update: Azure VMs
      "Microsoft.Compute/virtualMachines/assessPatches/action",
      "Microsoft.Compute/virtualMachines/installPatches/action",
      "Microsoft.Compute/locations/operations/read",
      "Microsoft.Compute/virtualMachines/patchAssessmentResults/read",
      "Microsoft.Compute/virtualMachines/patchAssessmentResults/softwarePatches/read",
      "Microsoft.Compute/virtualMachines/patchInstallationResults/read",
      "Microsoft.Compute/virtualMachines/patchInstallationResults/softwarePatches/read",

      # On-demand assessment + one-time update: Azure Arc-enabled servers
      "Microsoft.HybridCompute/machines/assessPatches/action",
      "Microsoft.HybridCompute/machines/installPatches/action",
      "Microsoft.HybridCompute/locations/updateCenterOperationResults/read",
      "Microsoft.HybridCompute/machines/patchAssessmentResults/read",
      "Microsoft.HybridCompute/machines/patchAssessmentResults/softwarePatches/read",
      "Microsoft.HybridCompute/machines/patchInstallationResults/read",
      "Microsoft.HybridCompute/machines/patchInstallationResults/softwarePatches/read",

      # Maintenance configurations (scheduled patching) incl. dynamic scopes
      "Microsoft.Maintenance/maintenanceConfigurations/read",
      "Microsoft.Maintenance/maintenanceConfigurations/write",
      "Microsoft.Maintenance/maintenanceConfigurations/maintenanceScope/InGuestPatch/write",
      "Microsoft.Maintenance/configurationAssignments/read",
      "Microsoft.Maintenance/configurationAssignments/write",
      "Microsoft.Maintenance/configurationAssignments/maintenanceScope/InGuestPatch/write",
    ]
    not_actions = []
  }

  assignable_scopes = [data.azurerm_subscription.current.id]
}

resource "azurerm_role_assignment" "function_update_manager" {
  scope              = data.azurerm_subscription.current.id
  role_definition_id = azurerm_role_definition.update_manager_operator.role_definition_resource_id
  principal_id       = azurerm_function_app_flex_consumption.this.identity[0].principal_id
  principal_type     = "ServicePrincipal"
}

# Read the exclusion table - scoped to that single table, not the whole account
resource "azurerm_role_assignment" "function_table_reader" {
  scope                = azurerm_storage_table.exclusions.resource_manager_id
  role_definition_name = "Storage Table Data Reader"
  principal_id         = azurerm_function_app_flex_consumption.this.identity[0].principal_id
  principal_type       = "ServicePrincipal"
}
