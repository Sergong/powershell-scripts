resource "netapp-ontap_network_interface" "lif" {
  svm_name       = var.svm_name
  name           = var.name
  ip             = var.ip_address
  netmask        = var.netmask
  home_node      = var.home_node
  home_port      = var.home_port
  service_policy = var.service_policy
  admin_status   = var.admin_status

  # Optional configurations
  dynamic "location" {
    for_each = var.location != null ? [var.location] : []
    content {
      failover_group = lookup(location.value, "failover_group", null)
      auto_revert    = lookup(location.value, "auto_revert", true)
    }
  }
}
