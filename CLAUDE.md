# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an Azure Infrastructure as Code (IaC) demonstration repository for Arpio disaster recovery scenarios. It deploys a Load Balancer - Server - Database stack using Azure Bicep templates.

## Common Commands

### Deploy Infrastructure
```bash
# Set subscription context
az account set --subscription <subscription_id>

# Create resource group (if needed)
az group create -n <resource_group_name> -l centralus

# Deploy the stack
az deployment group create \
  --name lb-server-db-bicep \
  --resource-group <resource_group_name> \
  --template-file demos/lb-server-db-iac/azuredeploy.bicep \
  --parameters demos/lb-server-db-iac/azuredeploy.bicepparam
```

### Local Flask App Testing
```bash
cd demos/lb-server-db-iac
bash scripts/run-local.sh
```

## Architecture

**3-Tier Stack:**
- **Load Balancer** (Standard SKU) → routes HTTP to backend VMs
- **Compute** (VMSS with 2-4 instances + standalone VM fallback) → runs Flask/Gunicorn
- **Database** (Azure SQL Basic tier with managed identity) → stores application messages, can BULK INSERT from blob storage

**Networking:**
- VNet: 10.0.0.0/16
- App Subnet: 10.0.0.0/24 (NSG: ports 22, 80)
- Bastion Subnet: 10.0.1.0/26
- NAT Gateway for all outbound traffic

**Key Files:**
- `demos/lb-server-db-iac/azuredeploy.bicep` - Main IaC template (all Azure resources)
- `demos/lb-server-db-iac/azuredeploy.bicepparam` - Deployment parameters
- `demos/lb-server-db-iac/scripts/app.py` - Flask web application
- `demos/lb-server-db-iac/scripts/vm-setup.sh` - VM initialization (runs via Custom Script Extension)
- `demos/lb-server-db-iac/scripts/sample-data.csv` - Sample CSV for BULK INSERT demo

**Deployment Flow:**
1. Bicep creates infrastructure + uploads scripts to blob storage
2. Custom Script Extension downloads and runs vm-setup.sh on VMs
3. Setup script installs Python dependencies and starts Flask via systemd/Gunicorn
4. VMs fetch DB credentials via Azure Instance Metadata Service (IMDS)

## Arpio Integration

Resources use Arpio-specific tagging for disaster recovery:
- Key Vault secrets tagged with `arpio-config:admin-password-secret` for Arpio credential management
- Future: System-assigned managed identities on VMs for identity recovery scenarios (see `PRIVATE-STORAGE-PLAN.md`)

## Flask App Routes

- `GET /` - Display hostname, DB status, NAT gateway IP, messages
- `POST /add` - Insert new message
- `POST /delete/<id>` - Delete message by ID
- `POST /import-from-blob` - Import messages from blob storage CSV

## Demo Features

**NAT Gateway**: All VM outbound traffic routes through the NAT Gateway, providing a static public IP. The app displays this IP on the main page (via ipify.org) to demonstrate outbound connectivity.

**Load Balancer**: Distributes HTTP traffic across VMs. The app displays the hostname to show which VM handled each request. Session persistence uses a fixed secret key so sessions work across VMs.

**Blob Storage**: Stores VM setup scripts (`vm-setup.sh`, `app.py`) and sample data (`sample-data.csv`). Scripts are uploaded during deployment and downloaded by VMs via Custom Script Extension.

**SQL Server Outbound Firewall**: The SQL Server has `restrictOutboundNetworkAccess: Enabled` with an outbound firewall rule for the specific storage account FQDN (e.g., `scriptsxxx.blob.core.windows.net`). Uses managed identity with Storage Blob Data Reader role. Wildcards (e.g., `*.blob.core.windows.net`) do NOT work - must use specific FQDN. The "Import from Blob" button demonstrates this by using `OPENROWSET` to read `sample-data.csv`.

## DR Considerations (Arpio)

After Arpio recovery:
- **Outbound firewall rules** may not be recovered - need to re-add manually
- **External data source URL** in SQL DB may point to old storage account - app handles this by checking and recreating if URL doesn't match `BLOB_STORAGE_URL` env var