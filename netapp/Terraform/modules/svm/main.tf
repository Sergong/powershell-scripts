resource "netapp-ontap_svm" "svm" {
  name    = var.name
  comment = var.comment

  # Language and encoding
  language = var.language
  
  # Aggregates allowed for this SVM
  dynamic "aggregates" {
    for_each = var.aggregates != null ? [var.aggregates] : []
    content {
      aggregates = aggregates.value
    }
  }

  # Protocols
  dynamic "protocols" {
    for_each = var.protocols != null ? [var.protocols] : []
    content {
      nfs_enabled   = lookup(protocols.value, "nfs_enabled", false)
      cifs_enabled  = lookup(protocols.value, "cifs_enabled", false)
      iscsi_enabled = lookup(protocols.value, "iscsi_enabled", false)
      fcp_enabled   = lookup(protocols.value, "fcp_enabled", false)
      nvme_enabled  = lookup(protocols.value, "nvme_enabled", false)
    }
  }

  # Security settings
  dynamic "security" {
    for_each = var.security_settings != null ? [var.security_settings] : []
    content {
      permitted_encryption_types = lookup(security.value, "permitted_encryption_types", null)
      kdc_vendor                 = lookup(security.value, "kdc_vendor", null)
    }
  }
}

# Create root volume for the SVM
resource "netapp-ontap_volume" "svm_root" {
  count = var.create_root_volume ? 1 : 0
  
  name                 = "${var.name}_root"
  svm_name            = netapp-ontap_svm.svm.name
  aggregates          = var.root_volume_aggregate != null ? [var.root_volume_aggregate] : []
  size                = var.root_volume_size
  security_style      = var.root_volume_security_style
  junction_path       = "/"
  volume_type         = "rw"
  
  # Snapshot configuration
  snapshot_policy = var.root_volume_snapshot_policy
}
