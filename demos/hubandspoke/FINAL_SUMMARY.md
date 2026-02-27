# Azure Hub-Spoke Deployment - Final Summary

## 📦 What You're Getting

### 4 Separate Resource Groups

```
{prefix}-hub-rg/
├── Hub VNet (10.0.0.0/16)
├── Azure Bastion (secure VM access)
├── VPN Gateway (30-45 min to deploy)
├── Route Tables
└── VNet Peering rules (Hub → App1, Hub → App2)

{prefix}-app1-rg/
├── App 1 VNet (10.1.0.0/16)
├── Public Load Balancer
├── Linux VMSS (Ubuntu 22.04 with Python HTTP server)
├── Database VM (Ubuntu 22.04 with MySQL)
├── NSGs & Application Security Groups
└── VNet Peering (App1 → Hub)

{prefix}-app2-rg/
├── App 2 VNet (10.2.0.0/16)
├── Windows Server 2022 VM
├── User Assigned Managed Identity
├── NSGs & Application Security Groups
└── VNet Peering (App2 → Hub)

{prefix}-paas-rg/ (optional)
├── Application Gateway VNet (10.254.0.0/16)
├── Application Gateway (public entry)
├── App Service (IP restricted to App Gateway only)
├── Azure SQL Database (public endpoint)
├── Key Vault (RBAC with managed identity)
├── Storage Account (2 containers + 1 queue)
└── Container Instance (public IP)
```

## 🔒 Security Model

### Hub-Spoke (IaaS)
- ✅ Azure Bastion is the **only** internet entry point for VMs
- ✅ VPN Gateway routes all spoke outbound traffic
- ✅ SSH/RDP blocked from internet (only via Bastion)
- ✅ Database VM isolated (only accessible from web subnet + Bastion)
- ✅ NSGs with deny-by-default rules
- ✅ Application Security Groups for granular control
- ✅ All VMs use same configurable SKU

### PaaS Application (optional)
- ✅ App Service **IP restricted** - only accessible via Application Gateway
- ✅ Container Instance has public IP (no restriction capability in ACI)
- ✅ Application Gateway is public entry point
- ✅ SQL Database uses public endpoint with Azure Services firewall rule
- ✅ Key Vault uses RBAC with App Service managed identity

## ⚙️ Configuration Options

### Deploy Script Prompts
1. Subscription ID
2. Resource prefix (e.g., "arpio-demo")
3. Azure region (works in ALL regions, including those without availability zones)
4. **Admin username/password** (used for ALL VMs and SQL Database)
5. VNet address spaces (defaults: 10.0.0.0/16, 10.1.0.0/16, 10.2.0.0/16)
6. **Single VM SKU for all VMs and VMSS** (default: Standard_B2s)
7. VMSS instance count (default: 2)
8. Deploy PaaS application? (yes/no)
9. PaaS Key Vault secret (if deploying PaaS)

## 📊 Cost Estimates

### Hub-Spoke Only (~$460/month)
- VPN Gateway (VpnGw1): ~$140
- Azure Bastion (Standard): ~$140
- VMs (VMSS + 2 VMs): ~$150
- Load Balancer (Standard): ~$20
- Public IPs & Networking: ~$10

### With PaaS Application (+$350/month)
- Application Gateway (Standard_v2): ~$150
- App Service (P1v3): ~$120
- SQL Database (Basic): ~$5
- Container Instance: ~$30
- Storage + Key Vault: ~$5
- Networking: ~$40

**Total with both: ~$810/month**

## ⏱️ Deployment Time

- **Hub-Spoke only**: 45-60 minutes (VPN Gateway bottleneck)
- **With PaaS**: 50-65 minutes

## 🚀 Quick Start

```bash
# Make script executable
chmod +x deploy.sh

# Run interactive deployment
./deploy.sh
```

The script will guide you through all options.

## 📂 File Organization

After downloading, organize like this:

```
your-project/
├── main.bicep                      # Main orchestrator
├── deploy.sh                       # Interactive deployment script
├── README.md                       # Full documentation
└── modules/
    ├── hub-vnet.bicep             # Hub VNet (Bastion + VPN)
    ├── app1-vnet.bicep            # App 1 (LB + VMSS + DB VM)
    ├── app2-vnet.bicep            # App 2 (Windows VM)
    ├── vnet-peering.bicep         # VNet peering
    └── paas-application.bicep     # PaaS stack (optional)
```

## 🌐 Access Your Deployment

### Via Azure Bastion (Recommended)
1. Go to Azure Portal
2. Navigate to `{prefix}-hub-rg`
3. Find the Bastion resource
4. Connect to any VM in the spoke VNets

### Via VPN Gateway
1. Wait for VPN Gateway to deploy (30-45 min)
2. Configure Point-to-Site VPN in Azure Portal
3. Download VPN client
4. Connect and access VMs via private IP

### App 1 Load Balancer
```bash
http://<load-balancer-public-ip>
```

### PaaS Application (if deployed)
```bash
# App Service via App Gateway
http://<app-gateway-ip>

# Container Instance via App Gateway
http://<app-gateway-ip>:8080

# Direct Container Instance access (also available)
http://<container-fqdn>:8080
```

## 🧹 Cleanup

Delete all resource groups:

```bash
PREFIX="your-prefix"

az group delete --name ${PREFIX}-hub-rg --yes --no-wait
az group delete --name ${PREFIX}-app1-rg --yes --no-wait
az group delete --name ${PREFIX}-app2-rg --yes --no-wait
az group delete --name ${PREFIX}-paas-rg --yes --no-wait
```

## ✅ Key Features

- ✅ **No zone dependencies** - Works in any Azure region
- ✅ **Modular design** - Each component in separate resource group
- ✅ **Single VM SKU** - One size applies to all VMs and VMSS
- ✅ **Unified credentials** - Same admin username/password for VMs and SQL Database
- ✅ **Production-ready** - Full NSG security, private networking
- ✅ **Optional PaaS** - Deploy hub-spoke alone or with PaaS
- ✅ **Well-documented** - Comprehensive README and inline comments

## 🎯 Use Cases

### Hub-Spoke Architecture
- Enterprise landing zone simulation
- VM-based disaster recovery testing
- Multi-tier application deployments
- Network security testing
- Bastion and VPN Gateway scenarios

### PaaS Application
- Modern cloud-native apps
- PaaS disaster recovery testing
- Microservices architectures
- Application Gateway routing demos
- Managed identity best practices

## 📝 Important Notes

1. **VPN Gateway takes 30-45 minutes** - This is normal Azure behavior
2. **Resource names must be unique** - Especially Key Vault and Storage Account
3. **Separate resource groups** - Makes cleanup and management easier
4. **App Service is locked down** - Only accessible via App Gateway
5. **Container Instance is public** - Azure ACI doesn't support IP restrictions

## 🆘 Need Help?

- See README.md for complete documentation
- Check Azure Portal deployment logs for errors
- Review NSG rules if connectivity issues
- Verify VNet peering status

## 🎉 You're All Set!

Download all the files, organize them as shown above, and run `./deploy.sh` to get started!

Happy deploying! 🚀
