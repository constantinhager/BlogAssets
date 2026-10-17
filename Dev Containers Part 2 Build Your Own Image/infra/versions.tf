terraform {
  required_version = ">= 1.14.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.10"
    }
  }

  # Remote state in the storage account created by scripts/New-GitHubOidcDeploymentIdentity.ps1.
  # resource_group_name / storage_account_name / container_name are passed via -backend-config
  # in the GitHub Actions workflow. Authentication: OIDC + Entra ID (no storage key).
  backend "azurerm" {
    key              = "devcontainer-registry.tfstate"
    use_oidc         = true
    use_azuread_auth = true
  }
}

provider "azurerm" {
  features {}

  # The deployment identity only has rights on one resource group, so it can't register
  # resource providers. The bootstrap script registers Microsoft.ContainerRegistry once.
  # "none" is the default in azurerm 5.x - it is set here to make that visible.
  resource_provider_registrations = "none"

  # subscription_id, tenant_id, client_id come from ARM_* environment variables (OIDC in GitHub Actions).
}
