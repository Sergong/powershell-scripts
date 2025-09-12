output "lif_name" {
  description = "The name of the created LIF"
  value       = netapp-ontap_network_interface.lif.name
}

output "lif_ip_address" {
  description = "The IP address of the created LIF"
  value       = netapp-ontap_network_interface.lif.ip
}

output "lif_id" {
  description = "The ID of the created LIF resource"
  value       = netapp-ontap_network_interface.lif.id
}

output "lif_home_node" {
  description = "The home node of the created LIF"
  value       = netapp-ontap_network_interface.lif.home_node
}

output "lif_home_port" {
  description = "The home port of the created LIF"
  value       = netapp-ontap_network_interface.lif.home_port
}

output "lif_current_node" {
  description = "The current node of the LIF"
  value       = netapp-ontap_network_interface.lif.current_node
}

output "lif_current_port" {
  description = "The current port of the LIF"
  value       = netapp-ontap_network_interface.lif.current_port
}

output "lif_admin_status" {
  description = "The administrative status of the LIF"
  value       = netapp-ontap_network_interface.lif.admin_status
}
