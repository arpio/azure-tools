# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an Azure Infrastructure as Code (IaC) demonstration repository for Arpio disaster recovery scenarios. It contains multiple demos, each showcasing a different Azure architecture that Arpio protects. All infrastructure is defined in Azure Bicep templates.

## Repository Structure

```
demos/
  lb-server-db-iac/     # Load Balancer + VMs + Azure SQL
  appgw-container-iac/  # App Gateway + Container Instances + Private Endpoints
  demo-app/             # Shared Flask app used by the container demo
  hubandspoke/          # Hub-spoke topology (subscription-scope)
  lamp-app/             # LAMP stack (AppGW + LB) for Network Sandbox testing
  guestbook-AzureSQL/   # Windows + IIS + Azure SQL (guestbook)
```

## Cross-Cutting Conventions

### Bicep Patterns
- `loadTextContent()` embeds scripts into blob storage at deploy time
- `uniqueString(resourceGroup().id)` generates unique resource name suffixes
- Implicit dependencies via variable references; explicit `dependsOn` where needed
- Parameters defined in `.bicepparam` files (Bicep-native parameter format)

### Arpio DR Integration
- Key Vault secrets tagged with `arpio-config:admin-password-secret` for credential management (VM/VMSS resources point to the secret URL via this tag)
- After recovery: outbound firewall rules may need manual re-creation
- After recovery: external data source URLs in SQL DB may need updating (apps handle this dynamically)

### General Azure Setup
```bash
az account set --subscription <subscription_id>
az group create -n <resource_group_name> -l centralus
```

---

## Demo: lb-server-db-iac (3-Tier VM Stack)

Load Balancer + VMSS + standalone VM + Azure SQL. Full 3-tier example with NAT Gateway for static outbound IP.

**Architecture:**
- **Load Balancer** (Standard SKU) → routes HTTP to backend VMs
- **Compute** (VMSS with 2-4 instances + standalone VM) → Flask/Gunicorn
- **Database** (Azure SQL Basic tier with managed identity) → CRUD + BULK INSERT from blob
- **VNet** 10.0.0.0/16, App Subnet 10.0.0.0/24 (NSG: 22, 80), Bastion Subnet 10.0.1.0/26
- **NAT Gateway** for static outbound IP

**Deployment flow:** Bicep creates infra + uploads scripts to blob → Custom Script Extension runs `vm-setup.sh` on VMs → VMs fetch DB credentials via IMDS `userData`.

**Deploy:**
```bash
az deployment group create \
  --name lb-server-db-bicep \
  --resource-group <resource_group_name> \
  --template-file demos/lb-server-db-iac/azuredeploy.bicep \
  --parameters demos/lb-server-db-iac/azuredeploy.bicepparam

# Local testing
cd demos/lb-server-db-iac && bash scripts/run-local.sh
```

**Key files:**
- `demos/lb-server-db-iac/azuredeploy.bicep` - All Azure resources
- `demos/lb-server-db-iac/scripts/app.py` - Flask app (hostname, DB status, NAT IP, messages)
- `demos/lb-server-db-iac/scripts/vm-setup.sh` - VM bootstrap (Python, ODBC, systemd/Gunicorn)
- `demos/lb-server-db-iac/PRIVATE-STORAGE-PLAN.md` - Future plans for managed identity-based storage access

**Gotchas:**
- **SQL Server outbound firewall:** `restrictOutboundNetworkAccess: Enabled` requires a firewall rule for the specific storage account FQDN. **Wildcards do NOT work** — must use the specific FQDN (e.g., `scriptsxxx.blob.core.windows.net`).

---

## Demo: appgw-container-iac (Container + Private Endpoints)

Application Gateway fronting Azure Container Instances, with private endpoints for backing services. Uses the `demo-app` Flask image.

**Architecture:**
- **Application Gateway** (public IP) → routes HTTP to container instances
- **ACI** (2 container groups) → runs `demo-app` Flask image
- **Private Endpoints** for Key Vault, Blob Storage, Queue Storage
- **VNet** 10.1.0.0/16: appgw (10.1.0.0/24), aci (10.1.1.0/24), pe (10.1.2.0/24)
- **ACR** with identity-based auth (managed identity, no admin credentials)

**Deploy:**
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

**Key files:**
- `demos/appgw-container-iac/azuredeploy.bicep` - Main template
- `demos/appgw-container-iac/acrPullRole.bicep` - ACR pull role assignment module
- `demos/demo-app/app.py` - Flask app (Key Vault secrets, blobs, queues, health check)
- `demos/demo-app/Dockerfile` - Container image (Python 3.11-slim, gunicorn)
- `demos/demo-app/build_image.sh` - Builds ACR + pushes image

---

## Demo: hubandspoke (Hub-Spoke Landing Zone)

Subscription-scoped hub-and-spoke topology with a shared VPN Gateway, plus optional standalone PaaS stack.

**Architecture:**
- **Subscription-scoped** `main.bicep` — creates three RGs: `<prefix>-hub-rg`, `<prefix>-app1-rg`, `<prefix>-app2-rg` (plus optional `<prefix>-paas-rg`)
- **Hub VNet**: Azure Bastion + VPN Gateway (`VpnGw1AZ`) + route tables (private route table forces spoke traffic through VPN GW; public allows direct internet return for load-balanced subnets)
- **App1**: Load Balancer + Linux VMSS (Ubuntu) + Linux DB VM (MySQL) + Key Vault
- **App2**: Windows Server 2022 VM with User-Assigned Managed Identity
- Bidirectional peerings hub ⇄ app1 and hub ⇄ app2, with gateway transit
- Optional PaaS module (not peered) — AppGW + App Service + Azure SQL + Key Vault + Storage + ACI

**Deploy:**
```bash
# Subscription-scoped — creates its own RGs. Interactive script prompts for prefix, location, admin creds.
cd demos/hubandspoke && ./deploy.sh
```

**Key files:**
- `demos/hubandspoke/main.bicep` - Orchestrator (subscription scope)
- `demos/hubandspoke/modules/hub-vnet.bicep` - Hub VNet + Bastion + VPN Gateway
- `demos/hubandspoke/modules/app1-vnet.bicep`, `app2-vnet.bicep` - Spokes
- `demos/hubandspoke/modules/vnet-peering.bicep` - Reusable peering module
- `demos/hubandspoke/deploy.sh` - Interactive deploy wrapper

**Deployment ordering** (derived from Bicep dependency graph):
1. **All three RGs** (`hub-rg`, `app1-rg`, `app2-rg`) create in parallel — no cross-references.
2. **Hub VNet module** starts as soon as `hub-rg` exists. Includes VPN Gateway (30–45 min).
3. **App1 + App2 VNet modules** wait for the entire hub-vnet module to complete (they consume `hubVnet.outputs.*`), then run in parallel.
4. **Peerings** (four modules in `main.bicep`) wait for both their local and remote VNets. Each peering lands in the RG of its **local** VNet — so hub-rg gets two (hub→app1, hub→app2), each spoke RG gets one.

**Gotchas:**
- **VPN Gateway SKU:** Only AZ SKUs (`VpnGw1AZ`–`VpnGw5AZ`) are supported — non-AZ variants were retired. AZ SKU requires the Public IP to be Standard SKU with `zones: ['1','2','3']`.
- **Zones are immutable:** Switching an existing regional Public IP to zonal means deleting it (and its dependent gateway) first before redeploying.

---

## Demo: lamp-app (LAMP + AppGW + LB Sandbox Demo)

LAMP stack fronted by both L7 (App Gateway) and L4 (Load Balancer) ingress, for testing Arpio Network Sandbox with both patterns.

**Architecture:**
- Ubuntu VM (Apache + PHP + SQL Server ODBC drivers) with managed identity
- **Application Gateway** (Standard_v2, L7) + **Load Balancer** (Standard, L4) — both front the same VM
- Azure SQL Server + Key Vault + Storage Account
- Deployed to `eastus2`; PHP dashboard renders metadata for all wired resources

**Deploy:**
```bash
cd demos/lamp-app/infrastructure && SQL_ADMIN_PASS='<password>' ./deploy.sh
```

**Key files:**
- `demos/lamp-app/infrastructure/main.bicep` - All resources
- `demos/lamp-app/infrastructure/cloud-init.yml` - VM bootstrap
- `demos/lamp-app/application/` - PHP dashboard sources

**Gotchas:**
- **DB login may fail on fresh deploy** due to timing — the VM tries to connect before the DB is fully ready. It resolves on its own; no retry logic needed.

---

## Demo: guestbook-AzureSQL (Windows + IIS + Azure SQL)

Windows guestbook app with IIS and Azure SQL. Two Bicep variants for RG-scoped vs subscription-scoped deployment.

**Architecture:**
- Windows Server 2022 VM with IIS + system-assigned managed identity
- Azure SQL Server + `GuestbookDb` (table `dbo.Guestbook` pre-created)
- Key Vault (RBAC) holds `sql-admin-password` and `vm-admin-password`; VM identity granted Secrets User
- Deployed to `eastus2`

**Deploy:**
```bash
cd demos/guestbook-AzureSQL && ./deploy-script.sh
```

**Key files:**
- `demos/guestbook-AzureSQL/deploy-script.sh` - Interactive deploy
- `demos/guestbook-AzureSQL/sqlvm-rg.bicep` - RG-scoped template
- `demos/guestbook-AzureSQL/sqlvm-subscription.bicep` - Subscription-scoped template
