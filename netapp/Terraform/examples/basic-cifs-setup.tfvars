# =============================================================================
# Basic CIFS Setup Example
# =============================================================================
# This example shows a simple CIFS configuration with existing SVM

# NetApp ONTAP Cluster
cluster_management_ip = "10.0.0.10"
cluster_admin_user    = "admin"

# Use existing SVM
create_svm  = false
svm_name    = "existing_svm"

# Create two LIFs for CIFS access
lifs = {
  cifs_lif1 = {
    ip_address = "10.0.1.100"
    netmask    = "255.255.255.0"
    home_node  = "cluster-01"
    home_port  = "e0d"
  }
  cifs_lif2 = {
    ip_address = "10.0.1.101"
    netmask    = "255.255.255.0"
    home_node  = "cluster-02"
    home_port  = "e0d"
  }
}

# CIFS Configuration
enable_cifs         = true
domain_admin_user   = "Administrator@corp.example.com"
cifs_server_name    = "ONTAP-CIFS"
domain_fqdn         = "corp.example.com"
organizational_unit = "CN=Computers,DC=corp,DC=example,DC=com"
domain_join_user    = "svc-ontap@corp.example.com"
dns_servers         = ["10.0.0.5", "10.0.0.6"]

tags = {
  Environment = "production"
  Purpose     = "file-services"
}
