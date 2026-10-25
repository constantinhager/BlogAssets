terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.11"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7"
    }
  }

  # Partial configuration - the values come from the workflow (-backend-config)
  backend "azurerm" {
    use_azuread_auth = true
  }
}

provider "azurerm" {
  features {
    key_vault {
      # Never purge credentials on destroy - soft delete keeps them recoverable
      purge_soft_delete_on_destroy               = false
      purge_soft_deleted_secrets_on_destroy      = false
      purge_soft_deleted_certificates_on_destroy = false
    }
  }
  storage_use_azuread = true
}
