# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an Azure Infrastructure as Code (IaC) demonstration repository for Arpio disaster recovery scenarios. It contains multiple demos, each showcasing a different Azure architecture that Arpio protects. All infrastructure is defined in Azure Bicep templates.

## Repository Structure

```
demos/
  lb-server-db-iac/     # Demo 1: Load Balancer + VMs + Azure SQL
  appgw-container-iac/  # Demo 2: App Gateway + Container Instances + Private Endpoints
  demo-app/             # Shared Flask app used by the container demo
```

## Common Commands

### Demo 1: Load Balancer + VMs + SQL (lb-server-db-iac)

```bash
# Deploy
az deployment group create \
  --name lb-server-db-bicep \
  --resource-group <resource_group_name> \
  --template-file demos/lb-server-db-iac/azuredeploy.bicep \
  --parameters demos/lb-server-db-iac/azuredeploy.bicepparam

# Local testing
cd demos/lb-server-db-iac && bash scripts/run-local.sh
```

### Demo 2: App Gateway + Containers (appgw-container-iac)

```bash
# Step 1: Build container image (creates ACR + pushes image)
cd demos/demo-app && bash build_image.sh

# Step 2: Update azuredeploy.bicepparam with ACR name and image URI from step 1

# Step 3: Deploy
az deployment group create \
  --name appgw-aci-deploy \
  --resource-group <resource_group_name> \
  --template-file demos/appgw-container-iac/azuredeploy.bicep \
  --parameters demos/appgw-container-iac/azuredeploy.bicepparam

# Local testing of the container app
cd demos/demo-app && bash run-local.sh
```

### General Azure Setup

```bash
az account set --subscription <subscription_id>
az group create -n <resource_group_name> -l centralus
```

## Architecture

### Demo 1: lb-server-db-iac (3-Tier VM Stack)

- **Load Balancer** (Standard SKU) → routes HTTP to backend VMs
- **Compute** (VMSS with 2-4 instances + standalone VM) → Flask/Gunicorn
- **Database** (Azure SQL Basic tier with managed identity) → CRUD + BULK INSERT from blob
- **VNet** 10.0.0.0/16, App Subnet 10.0.0.0/24 (NSG: 22, 80), Bastion Subnet 10.0.1.0/26
- **NAT Gateway** for static outbound IP

**Deployment flow:** Bicep creates infra + uploads scripts to blob → Custom Script Extension runs `vm-setup.sh` on VMs → VMs fetch DB credentials via IMDS `userData`.

**Key files:**
- `demos/lb-server-db-iac/azuredeploy.bicep` - All Azure resources
- `demos/lb-server-db-iac/scripts/app.py` - Flask app (hostname, DB status, NAT IP, messages)
- `demos/lb-server-db-iac/scripts/vm-setup.sh` - VM bootstrap (Python, ODBC, systemd/Gunicorn)

### Demo 2: appgw-container-iac (Container + Private Endpoints)

- **Application Gateway** (public IP) → routes HTTP to container instances
- **ACI** (2 container groups) → runs `demo-app` Flask image
- **Private Endpoints** for Key Vault, Blob Storage, Queue Storage
- **VNet** 10.1.0.0/16: appgw (10.1.0.0/24), aci (10.1.1.0/24), pe (10.1.2.0/24)
- **ACR** with identity-based auth (managed identity, no admin credentials)

**Key files:**
- `demos/appgw-container-iac/azuredeploy.bicep` - Main template
- `demos/appgw-container-iac/acrPullRole.bicep` - ACR pull role assignment module
- `demos/demo-app/app.py` - Flask app (Key Vault secrets, blobs, queues, health check)
- `demos/demo-app/Dockerfile` - Container image (Python 3.11-slim, gunicorn)
- `demos/demo-app/build_image.sh` - Builds ACR + pushes image

## Bicep Patterns

- `loadTextContent()` embeds scripts into blob storage at deploy time
- `uniqueString(resourceGroup().id)` generates unique resource name suffixes
- Implicit dependencies via variable references; explicit `dependsOn` where needed
- Parameters defined in `.bicepparam` files (Bicep-native parameter format)

## Arpio DR Integration

- Key Vault secrets tagged with `arpio-config:admin-password-secret` for credential management
- After recovery: outbound firewall rules may need manual re-creation
- After recovery: external data source URLs in SQL DB may need updating (app handles this dynamically)
- `PRIVATE-STORAGE-PLAN.md` documents future plans for managed identity-based storage access

## SQL Server Outbound Firewall (lb-server-db-iac)

The SQL Server has `restrictOutboundNetworkAccess: Enabled` with a firewall rule for the specific storage account FQDN. Wildcards do NOT work - must use the specific FQDN (e.g., `scriptsxxx.blob.core.windows.net`).
