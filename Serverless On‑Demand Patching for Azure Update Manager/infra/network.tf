# Private subnet for the sample VM. The VM keeps no public IP.
# RDP is published through a Standard public load balancer and remains gated by the subnet NSG.
# Default outbound access is off, so outbound traffic (Windows Update!) goes through a NAT gateway.

resource "azurerm_virtual_network" "this" {
  name                = local.names.vnet
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = [var.vnet_address_space]
  tags                = var.tags
}

resource "azurerm_subnet" "vm" {
  name                            = "snet-vm"
  resource_group_name             = azurerm_resource_group.this.name
  virtual_network_name            = azurerm_virtual_network.this.name
  address_prefixes                = [cidrsubnet(var.vnet_address_space, 2, 0)]
  default_outbound_access_enabled = false
}

resource "azurerm_network_security_group" "vm" {
  name                = "nsg-${var.prefix}-vm"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

resource "azurerm_network_security_rule" "vm_rdp" {
  name                        = "Allow-Rdp-From-Lb"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "3389"
  source_address_prefix       = length(var.rdp_allowed_source_cidrs) == 1 ? var.rdp_allowed_source_cidrs[0] : null
  source_address_prefixes     = length(var.rdp_allowed_source_cidrs) > 1 ? var.rdp_allowed_source_cidrs : null
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.this.name
  network_security_group_name = azurerm_network_security_group.vm.name
}

resource "azurerm_public_ip" "rdp" {
  name                = local.names.rdp_public_ip
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_lb" "rdp" {
  name                = local.names.rdp_lb
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                 = "PublicFrontend"
    public_ip_address_id = azurerm_public_ip.rdp.id
  }
}

resource "azurerm_lb_nat_rule" "vm_rdp" {
  name                           = "Rdp"
  resource_group_name            = azurerm_resource_group.this.name
  loadbalancer_id                = azurerm_lb.rdp.id
  protocol                       = "Tcp"
  frontend_port                  = var.rdp_frontend_port
  backend_port                   = 3389
  frontend_ip_configuration_name = "PublicFrontend"
}

resource "azurerm_public_ip" "nat" {
  name                = "pip-${local.names.nat_gateway}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  name                = local.names.nat_gateway
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku_name            = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "vm" {
  subnet_id      = azurerm_subnet.vm.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}
