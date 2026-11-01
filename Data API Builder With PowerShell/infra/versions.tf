terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.12"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.10"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  # Partial configuration. The pipeline passes storage account, container, key,
  # use_oidc = true and use_azuread_auth = true with -backend-config.
  backend "azurerm" {}
}

# Authentication comes from the environment:
# ARM_CLIENT_ID, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID and ARM_USE_OIDC=true in GitHub Actions,
# your Azure CLI login locally. Both providers read the same variables.
provider "azurerm" {
  features {}

  # azurerm 5.x registers no resource providers by default.
  resource_providers_to_register = [
    "Microsoft.App",
    "Microsoft.ContainerRegistry",
    "Microsoft.ManagedIdentity",
    "Microsoft.OperationalInsights",
    "Microsoft.Sql",
  ]
}

provider "azuread" {}
