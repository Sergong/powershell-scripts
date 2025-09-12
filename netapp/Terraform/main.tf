# NetApp ONTAP Provider Configuration
provider "netapp-ontap" {
  cluster_management_ip = var.cluster_management_ip
  username             = var.cluster_admin_user
  password             = var.cluster_admin_password
  https                = true
  insecure_skip_verify = var.insecure_skip_verify
  validate_certs       = var.validate_certs
}

# Create or reference SVM
module "svm" {
  count  = var.create_svm ? 1 : 0
  source = "./modules/svm"

  name                         = var.svm_name
  comment                      = var.svm_comment
  language                     = var.svm_language
  aggregates                   = var.svm_aggregates
  protocols                    = var.svm_protocols
  security_settings            = var.svm_security_settings
  create_root_volume           = var.create_root_volume
  root_volume_aggregate        = var.root_volume_aggregate
  root_volume_size             = var.root_volume_size
  root_volume_security_style   = var.root_volume_security_style
  root_volume_snapshot_policy  = var.root_volume_snapshot_policy
  tags                         = var.tags
}

# Create LIFs
module "lifs" {
  source = "./modules/lif"
  
  for_each = var.lifs

  svm_name       = var.create_svm ? module.svm[0].svm_name : var.svm_name
  name           = each.key
  ip_address     = each.value.ip_address
  netmask        = each.value.netmask
  home_node      = each.value.home_node
  home_port      = each.value.home_port
  service_policy = each.value.service_policy
  admin_status   = lookup(each.value, "admin_status", "up")
  location       = lookup(each.value, "location", null)
  tags           = var.tags

  depends_on = [module.svm]
}

# Create CIFS Service (if enabled)
module "cifs" {
  count  = var.enable_cifs ? 1 : 0
  source = "./modules/cifs"

  svm_name               = var.create_svm ? module.svm[0].svm_name : var.svm_name
  cifs_server_name       = var.cifs_server_name
  domain_fqdn            = var.domain_fqdn
  admin_username         = var.domain_admin_user
  admin_password         = var.domain_admin_password
  domain_join_username   = var.domain_join_user
  domain_join_password   = var.domain_join_password
  organizational_unit    = var.organizational_unit
  dns_servers            = var.dns_servers
  netbios_enabled        = var.netbios_enabled
  allow_local_users      = var.allow_local_users
  security_settings      = var.cifs_security_settings
  cifs_shares            = var.cifs_shares
  svm_dependency         = var.create_svm ? module.svm[0] : null
  tags                   = var.tags

  depends_on = [module.svm, module.lifs]
}
