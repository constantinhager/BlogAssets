terraform {
  required_version = ">= 1.9"

  # Partial configuration. The GitHub workflow passes the values with -backend-config.
  backend "azurerm" {
    use_azuread_auth = true
  }

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  subscription_id = var.subscription_id

  # Storage accounts have shared key access disabled, so the provider must use Entra ID.
  storage_use_azuread = true

  # azurerm 5.x registers no resource providers by default.
  # New-GitHubDeploymentIdentity.ps1 registers the ones this project needs.

  features {}
}
