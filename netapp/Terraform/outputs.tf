# =============================================================================
# SVM Outputs
# =============================================================================

output "svm_name" {
  description = "Name of the SVM"
  value       = var.create_svm ? module.svm[0].svm_name : var.svm_name
}

output "svm_id" {
  description = "ID of the SVM (if created)"
  value       = var.create_svm ? module.svm[0].svm_id : null
}

output "svm_uuid" {
  description = "UUID of the SVM (if created)"
  value       = var.create_svm ? module.svm[0].svm_uuid : null
}

# =============================================================================
# LIF Outputs
# =============================================================================

output "lif_details" {
  description = "Details of all created LIFs"
  value = {
    for lif_name, lif in module.lifs : lif_name => {
      name         = lif.lif_name
      ip_address   = lif.lif_ip_address
      home_node    = lif.lif_home_node
      home_port    = lif.lif_home_port
      current_node = lif.lif_current_node
      current_port = lif.lif_current_port
      admin_status = lif.lif_admin_status
    }
  }
}

output "lif_ip_addresses" {
  description = "Map of LIF names to their IP addresses"
  value = {
    for lif_name, lif in module.lifs : lif_name => lif.lif_ip_address
  }
}

# =============================================================================
# CIFS Outputs
# =============================================================================

output "cifs_service" {
  description = "CIFS service details (if enabled)"
  value = var.enable_cifs ? {
    server_name         = module.cifs[0].cifs_server_name
    domain_fqdn         = module.cifs[0].domain_fqdn
    organizational_unit = module.cifs[0].organizational_unit
    dns_servers         = module.cifs[0].dns_servers
    netbios_enabled     = module.cifs[0].netbios_enabled
    allow_local_users   = module.cifs[0].allow_local_users
  } : null
}

output "cifs_shares" {
  description = "Details of created CIFS shares (if any)"
  value       = var.enable_cifs ? module.cifs[0].cifs_shares : {}
}

output "cifs_share_names" {
  description = "List of created CIFS share names"
  value       = var.enable_cifs ? module.cifs[0].cifs_share_names : []
}

# =============================================================================
# Summary Outputs
# =============================================================================

output "deployment_summary" {
  description = "Summary of the deployed NetApp ONTAP configuration"
  value = {
    cluster            = var.cluster_management_ip
    svm_name           = var.create_svm ? module.svm[0].svm_name : var.svm_name
    svm_created        = var.create_svm
    lif_count          = length(var.lifs)
    cifs_enabled       = var.enable_cifs
    cifs_shares_count  = var.enable_cifs ? length(var.cifs_shares) : 0
    tags               = var.tags
  }
}

