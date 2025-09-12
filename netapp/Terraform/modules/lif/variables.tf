variable "svm_name" {
  description = "Name of the SVM where the LIF will be created"
  type        = string
}

variable "name" {
  description = "Name of the network interface (LIF)"
  type        = string
}

variable "ip_address" {
  description = "IP address for the LIF"
  type        = string
  validation {
    condition     = can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$", var.ip_address))
    error_message = "IP address must be a valid IPv4 address."
  }
}

variable "netmask" {
  description = "Netmask for the LIF"
  type        = string
  default     = "255.255.255.0"
  validation {
    condition     = can(regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$", var.netmask))
    error_message = "Netmask must be a valid IPv4 netmask."
  }
}

variable "home_node" {
  description = "Home node for the LIF"
  type        = string
}

variable "home_port" {
  description = "Home port for the LIF"
  type        = string
}

variable "service_policy" {
  description = "Service policy for the LIF"
  type        = string
  default     = "default-data-files"
}

variable "admin_status" {
  description = "Administrative status of the LIF"
  type        = string
  default     = "up"
  validation {
    condition     = contains(["up", "down"], var.admin_status)
    error_message = "Admin status must be either 'up' or 'down'."
  }
}

variable "location" {
  description = "Location configuration for the LIF including failover settings"
  type = object({
    failover_group = optional(string)
    auto_revert    = optional(bool, true)
  })
  default = null
}

variable "tags" {
  description = "Tags to apply to the LIF for organization"
  type        = map(string)
  default     = {}
}
