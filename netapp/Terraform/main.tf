provider "netapp-ontap" {
  cluster_management_ip = var.cluster_management_ip
  username             = var.cluster_admin_user
  password             = var.cluster_admin_password
  https                = true
  insecure_skip_verify = true
}

resource "netapp-ontap_network_interface" "lif1" {
  svm_name       = var.svm_name
  name           = var.lif1_name
  ip             = var.lif1_ip
  netmask        = var.lif_netmask
  home_node      = var.lif1_home_node
  home_port      = var.lif1_home_port
  service_policy = var.service_policy
  admin_status   = "up"
}

resource "netapp-ontap_network_interface" "lif2" {
  svm_name       = var.svm_name
  name           = var.lif2_name
  ip             = var.lif2_ip
  netmask        = var.lif_netmask
  home_node      = var.lif2_home_node
  home_port      = var.lif2_home_port
  service_policy = var.service_policy
  admin_status   = "up"
}

resource "netapp-ontap_cifs_service" "cifs" {
  svm_name             = var.svm_name
  admin_username       = var.domain_admin_user
  admin_password       = var.domain_admin_password
  cifs_server          = var.cifs_server
  fqdn                 = var.domain_fqdn
  organizational_unit  = var.organizational_unit
  nbt                  = false
  ad_domain_username   = var.domain_join_user
  ad_domain_password   = var.domain_join_password
  dns_servers          = var.dns_servers
  allow_local_users    = false
}