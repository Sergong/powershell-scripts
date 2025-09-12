# NetApp ONTAP Cluster Configuration
cluster_management_ip = "10.0.0.1"
cluster_admin_user    = "admin"
# Set cluster_admin_password via: export TF_VAR_cluster_admin_password="your-password"

# SVM Configuration
create_svm   = false    # Set to true to create new SVM
svm_name     = "svm01"
svm_comment  = "CIFS SVM managed by Terraform"

# Network Interfaces (LIFs)
lifs = {
  lif01 = {
    ip_address = "192.168.1.101"
    netmask    = "255.255.255.0"
    home_node  = "ontap-node1"
    home_port  = "e0c"
  }
  lif02 = {
    ip_address = "192.168.1.102"
    netmask    = "255.255.255.0"
    home_node  = "ontap-node2"
    home_port  = "e0d"
  }
}

# CIFS Configuration
enable_cifs         = true
domain_admin_user   = "admin@example.com"
cifs_server_name    = "CIFS-SERVER01"
domain_fqdn         = "example.com"
organizational_unit = "OU=Storage,DC=example,DC=com"
domain_join_user    = "joinuser@example.com"
dns_servers         = ["8.8.8.8", "8.8.4.4"]

# Set passwords via environment variables:
# export TF_VAR_domain_admin_password="your-domain-admin-password"
# export TF_VAR_domain_join_password="your-domain-join-password"

# Resource Tags
tags = {
  Environment = "development"
  Team        = "infrastructure"
  ManagedBy   = "terraform"
}
