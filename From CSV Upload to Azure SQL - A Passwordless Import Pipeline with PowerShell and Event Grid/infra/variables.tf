variable "subscription_id" {
  type        = string
  description = "Target subscription."
}

variable "location" {
  type        = string
  default     = "germanywestcentral"
  description = "Region. Check Flex support: az functionapp list-flexconsumption-locations"
}

variable "prefix" {
  type        = string
  default     = "blob2sql"
  description = "Short name prefix (lowercase letters and digits, max 10 chars)."

  validation {
    condition     = can(regex("^[a-z0-9]{3,10}$", var.prefix))
    error_message = "Use 3-10 lowercase letters or digits."
  }
}

variable "powershell_version" {
  type        = string
  default     = "7.4"
  description = "PowerShell runtime version on Flex Consumption. List: az functionapp list-flexconsumption-runtimes --location <region> --runtime powershell"
}

variable "input_container_name" {
  type        = string
  default     = "incoming"
  description = "Must match BlobTrigger.Path in build/build.config.psd1."
}

variable "file_extensions" {
  type        = list(string)
  default     = [".csv"]
  description = "Blob name suffixes that trigger the import."
}

variable "csv_delimiter" {
  type        = string
  default     = "auto"
  description = "; , tab or auto (detect from the header line)."
}

variable "csv_encoding" {
  type        = string
  default     = "utf-8"
  description = "utf-8 or windows-1252 (classic Excel CSV export)."
}

variable "csv_source_timezone" {
  type        = string
  default     = "UTC"
  description = "Time zone for timestamps without offset, e.g. Europe/Berlin. Stored as UTC."
}

variable "sql_admin_login_name" {
  type        = string
  description = "Display name of the SQL admin principal (e.g. the Entra group sg-...-sql-admins)."
}

variable "sql_admin_object_id" {
  type        = string
  default     = null
  description = "Object ID of the SQL admin (Entra group with you + the CI service principal). Null = identity running Terraform."
}

variable "sql_database_sku" {
  type        = string
  default     = "Basic"
  description = "e.g. Basic, S0, GP_S_Gen5_1 (serverless)."
}

variable "client_ip_address" {
  type        = string
  default     = null
  description = "Your public IP, to run the schema/grant scripts against Azure SQL. Leave null to skip."
}

variable "enable_event_subscription" {
  type        = bool
  default     = false
  description = "Set to true AFTER the function code is deployed. Event Grid validates the webhook on creation."
}

variable "tags" {
  type    = map(string)
  default = {}
}
