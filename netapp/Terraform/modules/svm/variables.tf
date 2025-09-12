variable "name" {
  description = "Name of the SVM"
  type        = string
  validation {
    condition     = length(var.name) >= 1 && length(var.name) <= 41
    error_message = "SVM name must be between 1 and 41 characters."
  }
}

variable "comment" {
  description = "Comment for the SVM"
  type        = string
  default     = ""
}

variable "language" {
  description = "Language setting for the SVM"
  type        = string
  default     = "C.UTF-8"
}

variable "aggregates" {
  description = "List of aggregates allowed for this SVM"
  type        = list(string)
  default     = null
}

variable "protocols" {
  description = "Protocol configuration for the SVM"
  type = object({
    nfs_enabled   = optional(bool, false)
    cifs_enabled  = optional(bool, false)
    iscsi_enabled = optional(bool, false)
    fcp_enabled   = optional(bool, false)
    nvme_enabled  = optional(bool, false)
  })
  default = {
    nfs_enabled   = false
    cifs_enabled  = true
    iscsi_enabled = false
    fcp_enabled   = false
    nvme_enabled  = false
  }
}

variable "security_settings" {
  description = "Security settings for the SVM"
  type = object({
    permitted_encryption_types = optional(list(string))
    kdc_vendor                 = optional(string)
  })
  default = null
}

variable "create_root_volume" {
  description = "Whether to create a root volume for the SVM"
  type        = bool
  default     = true
}

variable "root_volume_aggregate" {
  description = "Aggregate for the root volume"
  type        = string
  default     = null
}

variable "root_volume_size" {
  description = "Size of the root volume"
  type        = string
  default     = "1GB"
}

variable "root_volume_security_style" {
  description = "Security style for the root volume"
  type        = string
  default     = "unix"
  validation {
    condition     = contains(["unix", "ntfs", "mixed"], var.root_volume_security_style)
    error_message = "Root volume security style must be unix, ntfs, or mixed."
  }
}

variable "root_volume_snapshot_policy" {
  description = "Snapshot policy for the root volume"
  type        = string
  default     = "default"
}

