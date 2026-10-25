variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "germanywestcentral"
}

variable "function_location" {
  description = "Region of the Flex Consumption Function App, if it differs from 'location' (Flex Consumption isn't available everywhere)."
  type        = string
  default     = null
}

variable "name_prefix" {
  description = "Short prefix for resource names."
  type        = string
  default     = "secrot"

  validation {
    condition     = can(regex("^[a-z0-9]{3,10}$", var.name_prefix))
    error_message = "name_prefix must be 3-10 lowercase letters or digits."
  }
}

variable "tags" {
  description = "Tags for all resources."
  type        = map(string)
  default = {
    workload = "entra-credential-rotation"
    source   = "terraform"
  }
}

variable "powershell_version" {
  description = "PowerShell version of the Function App."
  type        = string
  default     = "7.6"
}

# ---------- Rotation settings (become SR_* app settings) ----------

variable "threshold_days" {
  description = "Renew when the newest credential of an app expires within this many days."
  type        = number
  default     = 30
}

variable "expired_grace_days" {
  description = "Credentials that expired longer ago than this are reported as stale, not renewed."
  type        = number
  default     = 7
}

variable "secret_validity_days" {
  description = "Lifetime of a new client secret in days."
  type        = number
  default     = 180
}

variable "certificate_validity_months" {
  description = "Lifetime of a new certificate in months."
  type        = number
  default     = 12
}

variable "exclude_tag" {
  description = "Apps with this tag (app registration 'tags') are only reported; renewing them on request needs Force."
  type        = string
  default     = "SecretRotation:Exclude"
}

variable "backup_public_certificates" {
  description = "Copy the public part of existing app certificates to Key Vault."
  type        = bool
  default     = true
}

variable "state_table_name" {
  description = "Name of the renewal state table."
  type        = string
  default     = "CredentialRenewals"
}

# ---------- Notifications ----------

variable "mail_sender" {
  description = "Mailbox the notification is sent from (UPN or SMTP address). Empty = no mail."
  type        = string
  default     = ""
}

variable "mail_recipients" {
  description = "Recipients of the notification mail."
  type        = list(string)
  default     = []
}

# ---------- Rotation app (required) ----------

variable "rotation_app_id" {
  description = "Client ID of the multi-tenant rotation app (scripts/New-SecretRotationApp.ps1). Every Graph call - home and customer tenants - goes through it."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$", var.rotation_app_id))
    error_message = "rotation_app_id must be the client ID (GUID) of the rotation app."
  }
}

variable "customer_tenant_ids" {
  description = "Customer tenants to rotate credentials in, in addition to the home tenant. Each needs admin consent for the rotation app."
  type        = list(string)
  default     = []
}

# ---------- Access ----------

variable "admin_principal_ids" {
  description = "Object IDs of users or groups that approve renewals: 'Storage Table Data Contributor' on the state table and 'Key Vault Secrets Officer' (import existing secrets)."
  type        = list(string)
  default     = []
}

variable "key_vault_purge_protection" {
  description = "Purge protection for the Key Vault. Recommended for production; blocks reusing the vault name for the retention period after deletion."
  type        = bool
  default     = true
}
