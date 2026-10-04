# Sample Windows Server VM with the update tag.
# Patch orchestration "Customer Managed Schedules" = AutomaticByPlatform + bypass platform safety checks.
# That is required for maintenance configurations and works for on-demand assessment / one-time updates.

resource "random_password" "vm_admin" {
  length           = 24
  special          = true
  override_special = "!#%&*()-_=+[]{}<>:?"
  min_lower        = 2
  min_upper        = 2
  min_numeric      = 2
  min_special      = 2
}

resource "azurerm_network_interface" "vm" {
  name                = "nic-${local.names.vm}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_nat_rule_association" "vm_rdp" {
  network_interface_id  = azurerm_network_interface.vm.id
  ip_configuration_name = "ipconfig1"
  nat_rule_id           = azurerm_lb_nat_rule.vm_rdp.id
}

resource "azurerm_windows_virtual_machine" "sample" {
  name                  = local.names.vm
  location              = azurerm_resource_group.this.location
  resource_group_name   = azurerm_resource_group.this.name
  size                  = var.vm_size
  disk_controller_type  = var.vm_disk_controller_type
  admin_username        = var.vm_admin_username
  admin_password        = random_password.vm_admin.result
  network_interface_ids = [azurerm_network_interface.vm.id]

  # Azure Update Manager settings
  patch_mode                                             = "AutomaticByPlatform"
  patch_assessment_mode                                  = "AutomaticByPlatform" # periodic assessment every 24h
  bypass_platform_safety_checks_on_user_schedule_enabled = true                  # customer managed schedules
  hotpatching_enabled                                    = false

  # Trusted Launch
  secure_boot_enabled = true
  vtpm_enabled        = true

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = var.vm_image_sku
    version   = "latest"
  }

  boot_diagnostics {}

  # The tag the functions work with, e.g. UpdateGroup = Wave1
  tags = merge(var.tags, {
    (var.update_tag_name) = var.update_tag_value
  })

  depends_on = [azurerm_subnet_nat_gateway_association.vm]
}
