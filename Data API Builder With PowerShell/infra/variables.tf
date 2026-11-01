variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "germanywestcentral"
}

variable "name_prefix" {
  description = "Short prefix for resource names (lowercase letters and digits)."
  type        = string
  default     = "dab"

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.name_prefix))
    error_message = "name_prefix must be 2-8 lowercase letters or digits."
  }
}

variable "sql_admin_group_name" {
  description = "Display name of the Entra ID group that is the SQL server's Microsoft Entra admin. Contains the GitHub Actions identity."
  type        = string
}

variable "sql_admin_group_object_id" {
  description = "Object ID of that group."
  type        = string
}

variable "sql_sku_name" {
  description = "SKU of the sample database. S0 = DTU model, Standard tier, 10 DTUs."
  type        = string
  default     = "S0"
}

variable "sql_max_size_gb" {
  description = "Maximum size of the database in GB. S0 allows up to 250 GB."
  type        = number
  default     = 2
}

variable "bootstrap_image" {
  description = "Image for the very first revision, before the pipeline has pushed the DAB image. Must answer HTTP on port 5000 (ASPNETCORE_HTTP_PORTS)."
  type        = string
  default     = "mcr.microsoft.com/dotnet/samples:aspnetapp"
}

variable "api_display_name" {
  description = "Display name of the Entra ID app registration that protects the API."
  type        = string
  default     = "Meetup Data API"
}

variable "tags" {
  description = "Tags for all Azure resources."
  type        = map(string)
  default = {
    workload = "data-api-builder-sample"
  }
}
