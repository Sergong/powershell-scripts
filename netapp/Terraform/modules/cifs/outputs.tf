output "cifs_service_id" {
  description = "The ID of the CIFS service"
  value       = netapp-ontap_cifs_service.cifs.id
}

output "cifs_server_name" {
  description = "The NetBIOS name of the CIFS server"
  value       = netapp-ontap_cifs_service.cifs.cifs_server
}

output "domain_fqdn" {
  description = "The domain FQDN that the CIFS server joined"
  value       = netapp-ontap_cifs_service.cifs.fqdn
}

output "organizational_unit" {
  description = "The organizational unit where the CIFS server was placed"
  value       = netapp-ontap_cifs_service.cifs.organizational_unit
}

output "dns_servers" {
  description = "The DNS servers configured for the CIFS service"
  value       = netapp-ontap_cifs_service.cifs.dns_servers
}

output "cifs_shares" {
  description = "Map of created CIFS shares with their details"
  value = {
    for share_name, share in netapp-ontap_cifs_share.shares : share_name => {
      name    = share.name
      path    = share.path
      comment = share.comment
      id      = share.id
    }
  }
}

output "cifs_share_names" {
  description = "List of created CIFS share names"
  value       = [for share in netapp-ontap_cifs_share.shares : share.name]
}

output "netbios_enabled" {
  description = "Whether NetBIOS is enabled for the CIFS service"
  value       = netapp-ontap_cifs_service.cifs.nbt
}

output "allow_local_users" {
  description = "Whether local users are allowed for CIFS authentication"
  value       = netapp-ontap_cifs_service.cifs.allow_local_users
}
