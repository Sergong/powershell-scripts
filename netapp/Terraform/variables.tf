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

variable "svm_name" {
  description = "Name of the SVM to configure"
  type        = string
}

variable "lif1_name" {
  description = "Name of the first LIF"
  type        = string
}

variable "lif1_ip" {
  description = "IP address of the first LIF"
  type        = string
}

variable "lif1_home_node" {
  description = "ONTAP node for the first LIF"
  type        = string
}

variable "lif1_home_port" {
  description = "ONTAP port for the first LIF"
  type        = string
}

variable "lif2_name" {
  description = "Name of the second LIF"
  type        = string
}

variable "lif2_ip" {
  description = "IP address of the second LIF"
  type        = string
}

variable "lif2_home_node" {
  description = "ONTAP node for the second LIF"
  type        = string
}

variable "lif2_home_port" {
  description = "ONTAP port for the second LIF"
  type        = string
}

variable "lif_netmask" {
  description = "Netmask for LIFs"
  type        = string
  default     = "255.255.255.0"
}

variable "service_policy" {
  description = "Service policy for LIFs"
  type        = string
  default     = "default-data-files"
}

variable "domain_admin_user" {
  description = "Domain admin username for CIFS service"
  type        = string
}

variable "domain_admin_password" {
  description = "Domain admin password for CIFS service"
  type        = string
  sensitive   = true
}

variable "cifs_server" {
  description = "NetBIOS name of the CIFS server"
  type        = string
}

variable "domain_fqdn" {
  description = "Fully qualified domain name"
  type        = string
}

variable "organizational_unit" {
  description = "Organizational Unit (OU) for the SVM in AD"
  type        = string
  default     = ""
}

variable "domain_join_user" {
  description = "User account for joining the domain"
  type        = string
}

variable "domain_join_password" {
  description = "Password for domain join user"
  type        = string
  sensitive   = true
}

variable "dns_servers" {
  description = "List of DNS server IPs"
  type        = list(string)
}