variable "svm_name" {
  description = "Name of the SVM where CIFS service will be configured"
  type        = string
}

variable "cifs_server_name" {
  description = "NetBIOS name of the CIFS server"
  type        = string
  validation {
    condition     = length(var.cifs_server_name) >= 1 && length(var.cifs_server_name) <= 15
    error_message = "CIFS server name must be between 1 and 15 characters."
  }
}

variable "domain_fqdn" {
  description = "Fully qualified domain name to join"
  type        = string
}

variable "admin_username" {
  description = "Domain administrator username for CIFS service configuration"
  type        = string
}

variable "admin_password" {
  description = "Domain administrator password for CIFS service configuration"
  type        = string
  sensitive   = true
}

variable "domain_join_username" {
  description = "Username for joining the domain (can be same as admin_username)"
  type        = string
  default     = null
}

variable "domain_join_password" {
  description = "Password for domain join user (can be same as admin_password)"
  type        = string
  sensitive   = true
  default     = null
}

variable "organizational_unit" {
  description = "Organizational Unit (OU) path for the CIFS server in Active Directory"
  type        = string
  default     = ""
}

variable "dns_servers" {
  description = "List of DNS server IP addresses"
  type        = list(string)
  validation {
    condition     = length(var.dns_servers) >= 1
    error_message = "At least one DNS server must be specified."
  }
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

variable "security_settings" {
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

variable "svm_dependency" {
  description = "Dependency reference to ensure SVM exists before creating CIFS service"
  type        = any
  default     = null
}

