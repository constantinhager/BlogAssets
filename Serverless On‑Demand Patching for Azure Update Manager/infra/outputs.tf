output "resource_group_name" {
  value = azurerm_resource_group.this.name
}

output "function_app_name" {
  value = azurerm_function_app_flex_consumption.this.name
}

output "function_app_hostname" {
  value = azurerm_function_app_flex_consumption.this.default_hostname
}

output "function_principal_id" {
  value = azurerm_function_app_flex_consumption.this.identity[0].principal_id
}

output "storage_account_name" {
  value = azurerm_storage_account.this.name
}

output "exclusion_table_name" {
  value = azurerm_storage_table.exclusions.name
}

output "sample_vm_name" {
  value = azurerm_windows_virtual_machine.sample.name
}

output "sample_vm_tag" {
  value = "${var.update_tag_name}=${var.update_tag_value}"
}
