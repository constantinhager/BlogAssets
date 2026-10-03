terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.40"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Remote state in the storage account created by scripts/New-GitHubOidcDeploymentIdentity.ps1.
  # resource_group_name / storage_account_name / container_name are passed via -backend-config
  # in the GitHub Actions workflow. Authentication: OIDC + Entra ID (no storage key).
  backend "azurerm" {
    key              = "azure-update-manager-automation.tfstate"
    use_oidc         = true
    use_azuread_auth = true
  }
}

provider "azurerm" {
  features {}
  # subscription_id, tenant_id, client_id come from ARM_* environment variables (OIDC in GitHub Actions).
}
