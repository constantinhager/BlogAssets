variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "germanywestcentral"
}

variable "function_location" {
  description = "Region for the Flex Consumption Function App. Defaults to var.location. Check availability with: az functionapp list-flexconsumption-locations"
  type        = string
  default     = null
}

variable "prefix" {
  description = "Short workload prefix used in resource names (lowercase letters and digits)."
  type        = string
  default     = "aum"

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.prefix))
    error_message = "prefix must be 2-8 lowercase letters or digits."
  }
}

variable "tags" {
  description = "Tags applied to all resources."
  type        = map(string)
  default = {
    workload  = "azure-update-manager-automation"
    managedBy = "terraform"
  }
}

# --- Sample VM -------------------------------------------------------------

variable "update_tag_name" {
  description = "Tag name the functions use to select machines."
  type        = string
  default     = "UpdateGroup"
}

variable "update_tag_value" {
  description = "Tag value of the sample VM."
  type        = string
  default     = "Wave1"
}

variable "vm_disk_controller_type" {
  description = "Disk controller of the sample VM. The v7 VM sizes only support NVMe (Windows Server 2025 images do), older sizes use SCSI."
  type        = string
  default     = "NVMe"

  validation {
    condition     = contains(["NVMe", "SCSI"], var.vm_disk_controller_type)
    error_message = "vm_disk_controller_type must be NVMe or SCSI."
  }
}

variable "vm_size" {
  description = "Size of the sample VM. Must support Trusted Launch (Gen 2) and be available in the subscription. Check with: Get-AzComputeResourceSku -Location <region>"
  type        = string
  default     = "Standard_D2s_v7"
}

variable "vm_admin_username" {
  description = "Local admin user of the sample VM."
  type        = string
  default     = "aumadmin"
}

variable "vm_image_sku" {
  description = "Windows Server image SKU. Use a non-Azure-Edition SKU: hotpatching (Azure Edition) conflicts with customer-managed schedules."
  type        = string
  default     = "2025-datacenter-g2"
}

variable "vnet_address_space" {
  description = "Address space of the sample VNet."
  type        = string
  default     = "10.20.0.0/24"
}

# --- Function App ----------------------------------------------------------

variable "powershell_version" {
  description = "PowerShell version of the Flex Consumption Function App (7.4 reaches end of support in November 2026)."
  type        = string
  default     = "7.6"
}

variable "function_maximum_instance_count" {
  description = "Scale-out limit of the Function App."
  type        = number
  default     = 40
}

variable "exclusion_table_name" {
  description = "Name of the Azure Table that holds the excluded KBs."
  type        = string
  default     = "UpdateExclusions"
}

variable "sample_exclusions" {
  description = "Seed rows for the exclusion table. Key = '<PartitionKey>/<RowKey>'. PartitionKey 'Global' applies to every run, any other value only to machines with that tag value."
  type = map(object({
    title  = string
    reason = string
  }))
  default = {
    "Global/KB5122871" = {
      title  = "2026-09 Security Update for Windows Server 2025"
      reason = "Example: RDS BUG"
    }
  }
}
