variable "resource_group_name" {
  description = "Existing resource group for the registry. Created by the bootstrap script - the deployment identity only has rights there."
  type        = string
}

variable "registry_name" {
  description = "Globally unique name of the Azure Container Registry (5-50 alphanumeric characters)."
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9]{5,50}$", var.registry_name))
    error_message = "registry_name must be 5-50 alphanumeric characters."
  }
}

variable "registry_sku" {
  description = "Basic is enough for a few dev container images. Standard or Premium add storage, throughput and (Premium) private endpoints."
  type        = string
  default     = "Basic"

  validation {
    condition     = contains(["Basic", "Standard", "Premium"], var.registry_sku)
    error_message = "registry_sku must be Basic, Standard or Premium."
  }
}

variable "image_repository" {
  description = "Repository of the dev container image inside the registry."
  type        = string
  default     = "devcontainers/devops"
}

variable "image_push_principal_id" {
  description = "Object ID of the service principal that pushes the image (GitHub Actions image identity). Gets AcrPush."
  type        = string
}

variable "acr_pull_principal_ids" {
  description = "Object IDs of Entra ID groups or users that may pull the image (your team). Each one gets AcrPull."
  type        = list(string)
  default     = []
}

variable "codespaces_token_enabled" {
  description = "Create a repository-scoped token (pull only) for GitHub Codespaces. Codespaces can't sign in with Entra ID."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags for all resources."
  type        = map(string)
  default = {
    project = "devcontainer-images"
    source  = "BlogAssets/Dev Containers Part 2"
  }
}
