# =============================================================================
# Complete SVM Setup Example
# =============================================================================
# This example creates a new SVM with CIFS service and shares

# NetApp ONTAP Cluster
cluster_management_ip = "10.0.0.10"
cluster_admin_user    = "admin"

# Create new SVM
create_svm           = true
svm_name             = "new_cifs_svm"
svm_comment          = "New CIFS SVM created by Terraform"
create_root_volume   = true
root_volume_size     = "2GB"

# SVM Protocol Configuration
svm_protocols = {
  cifs_enabled = true
  nfs_enabled  = false
}

# Create LIFs for the new SVM
lifs = {
  data_lif1 = {
    ip_address = "10.0.2.50"
    netmask    = "255.255.255.0"
    home_node  = "ontap-node1"
    home_port  = "e0c"
  }
  data_lif2 = {
    ip_address = "10.0.2.51"
    netmask    = "255.255.255.0"
    home_node  = "ontap-node2"
    home_port  = "e0c"
  }
}

# CIFS Configuration
enable_cifs         = true
domain_admin_user   = "admin@lab.local"
cifs_server_name    = "LAB-STORAGE"
domain_fqdn         = "lab.local"
domain_join_user    = "svc-storage@lab.local"
dns_servers         = ["10.0.0.10", "10.0.0.11"]
netbios_enabled     = true
allow_local_users   = false

# Advanced security settings
cifs_security_settings = {
  smb_encryption   = true
  session_security = "krb5"
}

# CIFS Shares
cifs_shares = {
  users = {
    path    = "/vol_users"
    comment = "User home directories"
  }
  shared = {
    path    = "/vol_shared"
    comment = "Shared data volume"
  }
}

tags = {
  Environment = "lab"
  Team        = "storage"
  Purpose     = "testing"
  ManagedBy   = "terraform"
}
