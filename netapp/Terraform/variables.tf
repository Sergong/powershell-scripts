# =============================================================================
# NetApp ONTAP Provider Configuration
# =============================================================================

variable "cluster_management_ip" {
  description = "ONTAP cluster management IP address"
  type        = string
}

variable "cluster_admin_user" {
  description = "ONTAP cluster admin username"
  type        = string
}

variable "cluster_admin_password" {
  description = "ONTAP cluster admin password"
  type        = string
  sensitive   = true
}

variable "insecure_skip_verify" {
  description = "Skip TLS certificate verification"
  type        = bool
  default     = true
}

variable "validate_certs" {
  description = "Enable certificate validation"
  type        = bool
  default     = false
}

# =============================================================================
# SVM Configuration
# =============================================================================

variable "create_svm" {
  description = "Whether to create a new SVM or use existing one"
  type        = bool
  default     = false
}

variable "svm_name" {
  description = "Name of the SVM to configure or create"
  type        = string
}

variable "svm_comment" {
  description = "Comment for the SVM"
  type        = string
  default     = "Created by Terraform"
}

variable "svm_language" {
  description = "Language setting for the SVM"
  type        = string
  default     = "C.UTF-8"
}

variable "svm_aggregates" {
  description = "List of aggregates allowed for this SVM"
  type        = list(string)
  default     = null
}

variable "svm_protocols" {
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

variable "svm_security_settings" {
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
}

variable "root_volume_snapshot_policy" {
  description = "Snapshot policy for the root volume"
  type        = string
  default     = "default"
}

# =============================================================================
# Network Interface (LIF) Configuration
# =============================================================================

variable "lifs" {
  description = "Map of LIFs to create"
  type = map(object({
    ip_address     = string
    netmask        = string
    home_node      = string
    home_port      = string
    service_policy = optional(string, "default-data-files")
    admin_status   = optional(string, "up")
    location = optional(object({
      failover_group = optional(string)
      auto_revert    = optional(bool, true)
    }))
  }))
  default = {}
}

# =============================================================================
# CIFS Configuration
# =============================================================================

variable "enable_cifs" {
  description = "Whether to enable and configure CIFS service"
  type        = bool
  default     = true
}

variable "domain_admin_user" {
  description = "Domain admin username for CIFS service"
  type        = string
  default     = ""
}

variable "domain_admin_password" {
  description = "Domain admin password for CIFS service"
  type        = string
  sensitive   = true
  default     = ""
}

variable "cifs_server_name" {
  description = "NetBIOS name of the CIFS server"
  type        = string
  default     = ""
}

variable "domain_fqdn" {
  description = "Fully qualified domain name"
  type        = string
  default     = ""
}

variable "organizational_unit" {
  description = "Organizational Unit (OU) for the SVM in AD"
  type        = string
  default     = ""
}

variable "domain_join_user" {
  description = "User account for joining the domain"
  type        = string
  default     = null
}

variable "domain_join_password" {
  description = "Password for domain join user"
  type        = string
  sensitive   = true
  default     = null
}

variable "dns_servers" {
  description = "List of DNS server IPs"
  type        = list(string)
  default     = []
}

variable "netbios_enabled" {
  description = "Enable NetBIOS over TCP/IP"
  type        = bool
  default     = false
}

variable "allow_local_users" {
  description = "Allow local user authentication"
  type        = bool
  default     = false
}

variable "cifs_security_settings" {
  description = "Advanced security settings for CIFS service"
  type = object({
    encrypt_data_connection    = optional(bool, false)
    kdc_encryption            = optional(bool, false)
    smb_encryption            = optional(bool, false)
    aes_netlogon_enabled      = optional(bool, false)
    try_ldap_channel_binding  = optional(bool, false)
    ldap_referral_enabled     = optional(bool, false)
    session_security          = optional(string, "none")
  })
  default = null
}

variable "cifs_shares" {
  description = "Map of CIFS shares to create"
  type = map(object({
    path    = string
    comment = optional(string, "")
    acl = optional(list(object({
      access_control = string
      permission     = string
      user_or_group  = string
    })), [])
    share_properties = optional(list(object({
      browsable              = optional(bool, true)
      change_notify          = optional(bool, true)
      continuously_available = optional(bool, false)
      encryption             = optional(bool, false)
      home_directory         = optional(bool, false)
      no_strict_security     = optional(bool, false)
      offline_files          = optional(string, "manual")
      oplocks                = optional(bool, true)
      show_snapshot          = optional(bool, false)
    })), [])
  }))
  default = {}
}

# =============================================================================
# Global Configuration
# =============================================================================

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
