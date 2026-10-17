data "azurerm_resource_group" "this" {
  name = var.resource_group_name
}

#region Container registry
resource "azurerm_container_registry" "this" {
  name                = var.registry_name
  resource_group_name = data.azurerm_resource_group.this.name
  location            = data.azurerm_resource_group.this.location
  sku                 = var.registry_sku

  # No shared admin password. People sign in with Entra ID, Codespaces with a scoped token.
  admin_enabled = false

  # AcrPull / AcrPush on the registry. The other mode (AbacRepositoryPermissions) needs the
  # "Container Registry Repository ..." roles instead.
  role_assignment_mode = "LegacyRegistryPermissions"

  tags = var.tags
}
#endregion

#region Permissions (Entra ID)
# GitHub Actions image identity: push (includes pull)
resource "azurerm_role_assignment" "image_push" {
  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPush"
  principal_id         = var.image_push_principal_id
  principal_type       = "ServicePrincipal"
  description          = "GitHub Actions pushes the dev container image"
}

# Team members: pull only
resource "azurerm_role_assignment" "pull" {
  for_each = toset(var.acr_pull_principal_ids)

  scope                = azurerm_container_registry.this.id
  role_definition_name = "AcrPull"
  principal_id         = each.value
  description          = "Pull the dev container image"
}
#endregion

#region GitHub Codespaces: repository-scoped token, pull only
# Codespaces authenticates with user name + password (<NAME>_CONTAINER_REGISTRY_* secrets).
# The token can read this one repository and nothing else. Terraform creates the token
# without a password - scripts/Set-CodespacesRegistrySecret.ps1 generates one with an expiry date,
# so the password never lands in the Terraform state.
resource "azurerm_container_registry_scope_map" "codespaces" {
  count = var.codespaces_token_enabled ? 1 : 0

  name                    = "codespaces-pull"
  container_registry_name = azurerm_container_registry.this.name
  resource_group_name     = data.azurerm_resource_group.this.name
  description             = "Pull ${var.image_repository} from GitHub Codespaces"
  actions = [
    "repositories/${var.image_repository}/content/read",
    "repositories/${var.image_repository}/metadata/read",
  ]
}

resource "azurerm_container_registry_token" "codespaces" {
  count = var.codespaces_token_enabled ? 1 : 0

  name                    = "codespaces-pull"
  container_registry_name = azurerm_container_registry.this.name
  resource_group_name     = data.azurerm_resource_group.this.name
  scope_map_id            = azurerm_container_registry_scope_map.codespaces[0].id
}
#endregion
