output "svm_name" {
  description = "The name of the created SVM"
  value       = netapp-ontap_svm.svm.name
}

output "svm_id" {
  description = "The ID of the created SVM"
  value       = netapp-ontap_svm.svm.id
}

output "svm_uuid" {
  description = "The UUID of the created SVM"
  value       = netapp-ontap_svm.svm.uuid
}

output "svm_state" {
  description = "The current state of the SVM"
  value       = netapp-ontap_svm.svm.state
}

output "svm_language" {
  description = "The language setting of the SVM"
  value       = netapp-ontap_svm.svm.language
}

output "root_volume_name" {
  description = "The name of the root volume (if created)"
  value       = var.create_root_volume ? netapp-ontap_volume.svm_root[0].name : null
}

output "root_volume_id" {
  description = "The ID of the root volume (if created)"
  value       = var.create_root_volume ? netapp-ontap_volume.svm_root[0].id : null
}

output "protocols" {
  description = "The protocols enabled on the SVM"
  value       = var.protocols
}
