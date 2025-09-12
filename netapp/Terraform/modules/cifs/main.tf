resource "netapp-ontap_cifs_service" "cifs" {
  svm_name             = var.svm_name
  admin_username       = var.admin_username
  admin_password       = var.admin_password
  cifs_server          = var.cifs_server_name
  fqdn                 = var.domain_fqdn
  organizational_unit  = var.organizational_unit
  nbt                  = var.netbios_enabled
  ad_domain_username   = var.domain_join_username
  ad_domain_password   = var.domain_join_password
  dns_servers          = var.dns_servers
  allow_local_users    = var.allow_local_users

  # Optional security settings
  dynamic "security" {
    for_each = var.security_settings != null ? [var.security_settings] : []
    content {
      encrypt_data_connection    = lookup(security.value, "encrypt_data_connection", false)
      kdc_encryption             = lookup(security.value, "kdc_encryption", false)
      smb_encryption             = lookup(security.value, "smb_encryption", false)
      aes_netlogon_enabled       = lookup(security.value, "aes_netlogon_enabled", false)
      try_ldap_channel_binding   = lookup(security.value, "try_ldap_channel_binding", false)
      ldap_referral_enabled      = lookup(security.value, "ldap_referral_enabled", false)
      session_security           = lookup(security.value, "session_security", "none")
    }
  }

  # Depends on SVM being available
  depends_on = [var.svm_dependency]
}

# Optional: Create CIFS shares if specified
resource "netapp-ontap_cifs_share" "shares" {
  for_each = var.cifs_shares

  svm_name           = var.svm_name
  name               = each.key
  path               = each.value.path
  comment            = lookup(each.value, "comment", "")
  acl                = lookup(each.value, "acl", [])
  
  # Share properties
  dynamic "share_properties" {
    for_each = lookup(each.value, "share_properties", [])
    content {
      browsable                = lookup(share_properties.value, "browsable", true)
      change_notify            = lookup(share_properties.value, "change_notify", true)
      continuously_available   = lookup(share_properties.value, "continuously_available", false)
      encryption               = lookup(share_properties.value, "encryption", false)
      home_directory          = lookup(share_properties.value, "home_directory", false)
      no_strict_security      = lookup(share_properties.value, "no_strict_security", false)
      offline_files           = lookup(share_properties.value, "offline_files", "manual")
      oplocks                 = lookup(share_properties.value, "oplocks", true)
      show_snapshot           = lookup(share_properties.value, "show_snapshot", false)
    }
  }

  depends_on = [netapp-ontap_cifs_service.cifs]
}
