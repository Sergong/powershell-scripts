# Terraform NetApp ONTAP Examples

This directory contains example configurations for different NetApp ONTAP deployment scenarios using the modular Terraform approach.

## Available Examples

### 1. Basic CIFS Setup (`basic-cifs-setup.tfvars`)
- Uses an existing SVM
- Creates LIFs for CIFS access
- Configures CIFS service with domain join
- Simple production-ready setup

**Usage:**
```bash
terraform plan -var-file="examples/basic-cifs-setup.tfvars"
terraform apply -var-file="examples/basic-cifs-setup.tfvars"
```

### 2. Complete SVM Setup (`complete-svm-setup.tfvars`)
- Creates a new SVM from scratch
- Configures protocols (CIFS enabled, NFS disabled)
- Creates LIFs and CIFS service
- Sets up basic CIFS shares
- Includes advanced security settings

**Usage:**
```bash
terraform plan -var-file="examples/complete-svm-setup.tfvars"
terraform apply -var-file="examples/complete-svm-setup.tfvars"
```

## Required Environment Variables

Before running any example, set the required passwords:

```bash
# Required for all examples
export TF_VAR_cluster_admin_password="your-cluster-admin-password"
export TF_VAR_domain_admin_password="your-domain-admin-password"
export TF_VAR_domain_join_password="your-domain-join-password"
```

## Customizing Examples

1. Copy an example file to your own `.tfvars` file
2. Modify the values to match your environment
3. Add or remove LIFs as needed
4. Adjust CIFS shares configuration
5. Update tags to match your organization's standards

## Module Structure

The examples use the following modules:
- **SVM Module** (`modules/svm/`) - Creates and manages SVMs
- **LIF Module** (`modules/lif/`) - Creates network interfaces
- **CIFS Module** (`modules/cifs/`) - Configures CIFS services and shares

Each module is self-contained and reusable across different configurations.
