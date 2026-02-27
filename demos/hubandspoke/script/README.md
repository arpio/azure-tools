# Azure Hub-Spoke Architecture Deployment

Complete Bicep templates for deploying a production-ready hub-spoke network architecture with landing zone simulation.

## Architecture Overview

```
                                Internet
                                    │
                    ┌───────────────┼───────────────┐
                    │               │               │
                    │         ┌─────▼──────┐       │
                    │         │   Bastion  │       │
                    │         │  (Public)  │       │
                    │         └────────────┘       │
                    │                               │
    ┌───────────────┴───────────────────────────────┴────────────────┐
    │                      Hub VNet (10.0.0.0/16)                     │
    │                                                                  │
    │   ┌─────────────┐      ┌─────────────┐      ┌──────────────┐ │
    │   │   Bastion   │      │VPN Gateway  │      │ Management   │ │
    │   │   Subnet    │      │   Subnet    │      │   Subnet     │ │
    │   └─────────────┘      └─────────────┘      └──────────────┘ │
    │                                                                  │
    └──────────────────────┬──────────────────┬──────────────────────┘
                           │                  │
                 ┌─────────▼────────┐  ┌──────▼──────────┐
                 │                  │  │                 │
    ┌────────────▼────────────────┐ │  │ ┌───────────────▼──────────────┐
    │  App 1 VNet (10.1.0.0/16)   │ │  │ │ App 2 VNet (10.2.0.0/16)     │
    │                              │ │  │ │                              │
    │  ┌───────────────────────┐  │ │  │ │ ┌─────────────────────────┐ │
    │  │  Web Subnet           │  │ │  │ │ │   App Subnet            │ │
    │  │                       │  │ │  │ │ │                         │ │
    │  │ ┌─────────────────┐  │  │ │  │ │ │ ┌────────────────────┐ │ │
    │  │ │ Load Balancer   │  │  │ │  │ │ │ │  Windows VM        │ │ │
    │  │ │  (Public IP)    │  │  │ │  │ │ │ │  + User Identity   │ │ │
    │  │ └────────┬────────┘  │  │ │  │ │ │ │  + ASG             │ │ │
    │  │          │            │  │ │  │ │ │ └────────────────────┘ │ │
    │  │   ┌──────▼──────┐    │  │ │  │ │ └─────────────────────────┘ │
    │  │   │  Linux VMSS │    │  │ │  │ └──────────────────────────────┘
    │  │   │ (System ID) │    │  │ │  │
    │  │   └─────────────┘    │  │ │  │
    │  └───────────────────────┘  │ │  │
    │                              │ │  │
    │  ┌───────────────────────┐  │ │  │
    │  │  Database Subnet      │  │ │  │
    │  │                       │  │ │  │
    │  │   ┌──────────────┐   │  │ │  │
    │  │   │  Linux DB VM │   │  │ │  │
    │  │   │  (MySQL)     │   │  │ │  │
    │  │   └──────────────┘   │  │ │  │
    │  └───────────────────────┘  │ │  │
    └──────────────────────────────┘ └──┘
```

## What Gets Deployed

### Resource Groups
The deployment creates **separate resource groups** for each component:
- **`{prefix}-hub-rg`** - Hub VNet with Bastion and VPN Gateway
- **`{prefix}-app1-rg`** - App 1 VNet with Load Balancer, VMSS, Database VM, Key Vault
- **`{prefix}-app2-rg`** - App 2 VNet with Windows VM
- **`{prefix}-paas-rg`** - PaaS Application (if deployed)

VNet peering connections are managed in the Hub resource group.

### Hub VNet (Landing Zone)
- **Azure Bastion** - Secure RDP/SSH access (only internet entry point)
- **VPN Gateway** - On-premises connectivity (30-45 min deployment)
- **Network Security Groups** - Restricts all inbound traffic except to Bastion
- **Route Table** - Routes spoke traffic through VPN Gateway

### App 1 VNet (Multi-Tier Application)
#### Key Vault
- **`{prefix}-app1-kv`** - Stores the VM admin password as a secret named `AdminPassword`
  - Name is derived as `{take(prefix, 15)}-app1-kv` to stay within the 24-character Key Vault name limit
  - RBAC-based access control
  - The VMSS is tagged with `arpio-config:admin-password-secret` pointing to the secret URL

#### Web Subnet
- **Public Load Balancer** - Distributes HTTP/HTTPS traffic
- **Linux VMSS** (Ubuntu 22.04) - Auto-scaling web tier with Python HTTP server (`python3 -m http.server 80`)
  - System Assigned Managed Identity
  - Application Security Group
  - Port 80 exposed via load balancer
  - SSH/RDP blocked from internet (only via Bastion)
  - Tagged with `arpio-config:admin-password-secret` → Key Vault secret URL

#### Database Subnet
- **Linux VM** (Ubuntu 22.04) - Database tier with MySQL
  - Only accessible from Web Subnet and Bastion
  - All outbound traffic routes through Hub VNet

### App 2 VNet (Windows Application)
- **Windows Server 2022 VM** - Application server
  - User Assigned Managed Identity
  - Application Security Group
  - All traffic routes through Hub VNet
  - RDP only via Bastion

### Network Security
- ✅ All inbound internet traffic blocked except to Bastion
- ✅ SSH/RDP only accessible via Bastion
- ✅ All spoke outbound traffic routes to VPN Gateway
- ✅ Database VM isolated to web subnet + bastion only
- ✅ Application Security Groups for granular security
- ✅ Hub-spoke peering with gateway transit

## Prerequisites

- Azure CLI installed
- Azure subscription with Contributor access
- Bash shell (Linux/macOS/WSL)

## Quick Start

```bash
./deploy.sh
```

The script will prompt for:
- Subscription ID
- Resource prefix
- Azure region
- Admin username/password
- VNet address spaces (optional)
- VM sizing (optional)

**Deployment time: 45-60 minutes** (VPN Gateway is the bottleneck)

## Manual Deployment

```bash
az login
az account set --subscription <subscription-id>

az deployment sub create \
  --name hub-spoke-deployment \
  --location eastus \
  --template-file main.bicep \
  --parameters \
    resourcePrefix="mycompany" \
    location="eastus" \
    adminUsername="azureuser" \
    adminPassword="YourSecurePassword123!" \
    hubVnetAddressPrefix="10.0.0.0/16" \
    app1VnetAddressPrefix="10.1.0.0/16" \
    app2VnetAddressPrefix="10.2.0.0/16"
```

### Deploy with Optional PaaS Application

You can optionally deploy a standalone PaaS application stack:

```bash
az deployment sub create \
  --name hub-spoke-with-paas \
  --location eastus \
  --template-file main.bicep \
  --parameters \
    resourcePrefix="mycompany" \
    location="eastus" \
    adminUsername="azureuser" \
    adminPassword="YourSecurePassword123!" \
    deployPaasApplication=true \
    paasSecretValue="MyPaasSecret123!"
```

**Note:** 
- The PaaS application is **standalone** and **not connected** to the hub-spoke VNets. 
- SQL Database uses the **same admin credentials** as the VMs (adminUsername/adminPassword).
- It creates its own minimal VNet for Application Gateway only.

## Project Structure

```
.
├── main.bicep                      # Orchestrator template
├── deploy.sh                       # Interactive deployment script
├── modules/
│   ├── hub-vnet.bicep             # Hub VNet with Bastion & VPN Gateway
│   ├── app1-vnet.bicep            # App 1 VNet with LB, VMSS, DB VM
│   ├── app2-vnet.bicep            # App 2 VNet with Windows VM
│   ├── vnet-peering.bicep         # VNet peering module
│   └── paas-application.bicep     # Optional PaaS application (standalone)
└── README.md                       # This file
```

## What is the PaaS Application?

The optional PaaS application module (`paas-application.bicep`) deploys a complete application stack using Azure PaaS services. It is **standalone** and **not integrated** with the hub-spoke VNets.

**PaaS Components:**
- Application Gateway (public entry point)
- App Service (Linux with .NET 8.0)
- Azure SQL Database
- Key Vault (with managed identity access)
- Storage Account (2 containers + 1 queue)
- Container Instance

**Key Characteristics:**
- ❌ Not connected to hub-spoke VNets
- ✅ Creates its own minimal VNet (10.254.0.0/16) for App Gateway only
- ✅ All resources accessible via public endpoints
- ✅ App Service connects to SQL Database via public endpoint
- ✅ Container Instance has public IP
- ✅ Ideal for demonstrating PaaS-based DR scenarios

## Parameters

### Required
| Parameter | Description | Example |
|-----------|-------------|---------|
| `resourcePrefix` | Prefix for all resources | `arpio-hub` |
| `location` | Azure region | `eastus` |
| `adminUsername` | VM admin username | `azureuser` |
| `adminPassword` | VM admin password | Must be 12+ chars |

### Optional
| Parameter | Description | Default |
|-----------|-------------|---------|
| `hubVnetAddressPrefix` | Hub VNet CIDR | `10.0.0.0/16` |
| `app1VnetAddressPrefix` | App 1 VNet CIDR | `10.1.0.0/16` |
| `app2VnetAddressPrefix` | App 2 VNet CIDR | `10.2.0.0/16` |
| `vmSize` | VM size for Linux VMs | `Standard_B2s` |
| `app2VmSize` | VM size for Windows VM | `Standard_B2ms` |
| `vmssInstanceCount` | VMSS instance count | `2` |

## Connecting to VMs

### Via Azure Bastion (Recommended)
1. Navigate to Azure Portal
2. Go to the Bastion resource in your resource group
3. Select the target VM
4. Click "Connect" and use Bastion

### Via VPN Gateway
1. Wait for VPN Gateway to finish deploying (30-45 min)
2. Configure Point-to-Site VPN in Azure Portal
3. Download VPN client configuration
4. Connect and access VMs directly via private IP

## Accessing Application

### App 1 Load Balancer
```bash
# Get the public IP
az network public-ip show \
  --resource-group <prefix>-rg \
  --name <prefix>-app1-lb-pip \
  --query ipAddress -o tsv

# Access via browser
http://<load-balancer-ip>
```

## Network Flow

### Inbound Traffic
```
Internet → Bastion Only
Internet → App 1 Load Balancer (ports 80/443) → VMSS
All other inbound traffic → BLOCKED
```

### Outbound Traffic
```
Spoke VNets → Hub VNet → VPN Gateway → Internet/On-Premises
```

### Inter-VNet Communication
```
App 1 ↔ Hub (via peering)
App 2 ↔ Hub (via peering)
App 1 ↔ App 2 (via Hub - no direct peering)
```

## Security Features

### Network Security
- NSGs on all subnets with deny-by-default
- SSH/RDP blocked from internet
- Database VM isolated to web tier only
- Application Security Groups for fine-grained control
- Route tables force traffic through Hub

### Identity & Access
- System Assigned Identity for VMSS — granted **Key Vault Secrets User** role on the App 1 Key Vault, enabling the `arpio-config:admin-password-secret` tag to resolve at recovery time
- User Assigned Identity for App 2 VM
- Azure Bastion for secure access
- No public IPs on VMs (except via load balancer)
- Key Vault in App 1 resource group stores admin password secret
- VMSS tagged with `arpio-config:admin-password-secret` for secret discovery

## Cost Estimate

Monthly costs (US East):
- VPN Gateway (VpnGw1): ~$140
- Azure Bastion (Standard): ~$140
- Load Balancer (Standard): ~$20
- VMs (2x B2s + 1x B2ms + VMSS): ~$150
- Public IPs: ~$10
- **Total: ~$460/month**

## Customization

### Change VMSS Instance Count
```bash
az vmss scale \
  --resource-group <prefix>-rg \
  --name <prefix>-app1-vmss \
  --new-capacity 5
```

### Modify VM Sizes
Edit the parameters in `main.bicep` or pass via command line:
```bash
--parameters vmSize="Standard_D2s_v3" app2VmSize="Standard_D4s_v3"
```

### Add More Spoke VNets
1. Copy `app1-vnet.bicep` or `app2-vnet.bicep`
2. Modify for your needs
3. Add peering in `main.bicep`
4. Deploy

## Troubleshooting

### VPN Gateway Deployment Timeout
The VPN Gateway takes 30-45 minutes. This is normal. If it fails:
```bash
# Check deployment status
az deployment sub show --name <deployment-name>

# Check VPN Gateway status
az network vnet-gateway show \
  --resource-group <prefix>-rg \
  --name <prefix>-vpn-gateway
```

### Cannot Connect to VMs
Ensure you're using Bastion or VPN Gateway connection. Direct internet access is blocked by design.

### Load Balancer Not Working
```bash
# Check backend health
az network lb show \
  --resource-group <prefix>-rg \
  --name <prefix>-app1-lb \
  --query backendAddressPools

# Check VMSS instances
az vmss list-instances \
  --resource-group <prefix>-rg \
  --name <prefix>-app1-vmss
```

## Cleanup

To remove all deployed resources, delete all resource groups:

```bash
# Delete all resource groups
az group delete --name <prefix>-hub-rg --yes --no-wait
az group delete --name <prefix>-app1-rg --yes --no-wait
az group delete --name <prefix>-app2-rg --yes --no-wait
az group delete --name <prefix>-paas-rg --yes --no-wait  # if PaaS was deployed

# Or use a loop
PREFIX="mycompany"
for rg in hub app1 app2 paas; do
  az group delete --name "${PREFIX}-${rg}-rg" --yes --no-wait 2>/dev/null
done
```

## Best Practices Implemented

✅ Hub-spoke topology with centralized security
✅ Gateway transit for spoke VNets
✅ Force tunneling through VPN Gateway
✅ No direct internet access to VMs
✅ Application Security Groups for micro-segmentation
✅ Managed identities instead of credentials
✅ Key Vault for admin credential storage (App 1)
✅ Deny-by-default NSG rules
✅ Separate subnets for web and database tiers

## Support

For issues or questions:
1. Check Azure deployment logs in Portal
2. Review NSG rules if connectivity issues
3. Verify peering status between VNets
4. Check route table configuration

## License

This project is provided as-is for demonstration and educational purposes.
