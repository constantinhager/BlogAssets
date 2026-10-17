output "registry_name" {
  description = "Name of the container registry."
  value       = azurerm_container_registry.this.name
}

output "login_server" {
  description = "Login server, e.g. acrdevcontainerx1y2z3.azurecr.io."
  value       = azurerm_container_registry.this.login_server
}

output "image" {
  description = "Full image name without tag - use it in devcontainer.json."
  value       = "${azurerm_container_registry.this.login_server}/${var.image_repository}"
}

output "codespaces_token_name" {
  description = "Name of the pull-only token for GitHub Codespaces (user name for docker login)."
  value       = var.codespaces_token_enabled ? azurerm_container_registry_token.codespaces[0].name : null
}
