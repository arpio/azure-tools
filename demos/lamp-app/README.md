# Arpio Bug Bash - Azure LAMP Stack with Network Sandbox Testing

This repository contains a complete Azure LAMP stack deployment designed for testing Arpio's Network Sandbox feature with both Application Gateway (Layer 7) and Load Balancer (Layer 4) ingress patterns.

## 🎯 What This Deploys

### Infrastructure Resources
- **Virtual Network** with subnet and NSG
- **Ubuntu VM** with Apache, PHP, and SQL Server drivers
- **Application Gateway** (Standard_v2) - Layer 7 load balancer
- **Load Balancer** (Standard) - Layer 4 TCP load balancer
- **Azure SQL Server** with database
- **Key Vault** for secrets management
- **Storage Account** for application data
- **Managed Identity** for VM authentication

### Application
- PHP dashboard showing:
  - VM metadata and configuration
  - Application Gateway details and routing
  - Load Balancer details and backend pools
  - SQL Server connection info
  - Key Vault and Storage Account details
  - Arpio Network Sandbox support indicators

## 🚀 Quick Start

### Prerequisites
- Azure CLI installed and logged in (`az login`)
- Active Azure subscription
- SSH key pair (will be auto-generated if not present)
- Bash shell (macOS, Linux, or WSL on Windows)

### Step 1: Deploy Infrastructure (~10-15 minutes)

```bash
cd infrastructure
SQL_ADMIN_PASS='YourSecurePassword123!' ./deploy.sh
```

**What this does:**
- Creates resource group in `eastus2`
- Deploys all infrastructure resources via Bicep
- Sets up VM with minimal bootstrap (Apache, PHP, dependencies)
- Configures networking, security, and managed identities

**Output:**
- VM Public IP
- Application Gateway URL
- Load Balancer URL
- SQL Server FQDN
- Key Vault name
- Storage Account name

### Step 2: Deploy Application (~30 seconds)

```bash
cd ../application
./deploy-app.sh
```

**What this does:**
- Gets VM IP from Azure
- Retrieves Application Gateway and Load Balancer resource IDs
- Copies PHP application to VM via SCP
- Deploys configuration to `/etc/arpio-lamp/`
- Restarts Apache

**Output:**
- Direct VM URL: `http://<VM_IP>`
- App Gateway URL: `http://<APPGW_IP>`
- Load Balancer URL: `http://<LB_IP>`

### Step 3: Test Network Sandbox with Arpio

1. Access application through each endpoint to verify functionality
2. Use Arpio to protect this environment
3. Enable Network Sandbox mode
4. Verify inbound traffic works via Application Gateway and Load Balancer
5. Verify outbound traffic is blocked (as expected in Network Sandbox)

## ⚙️ Customization

### Change Resource Names

Set `RESOURCE_PREFIX` to customize all resource names:

```bash
cd infrastructure
RESOURCE_PREFIX="alice" SQL_ADMIN_PASS='Password123!' ./deploy.sh
```

This creates: `alice-rg`, `alice-vm`, `alice-appgw`, `alice-lb`, etc.

### Change Azure Region

```bash
REGION="westus2" SQL_ADMIN_PASS='Password123!' ./deploy.sh
```

### Change VM Size

```bash
VM_SIZE="Standard_D2s_v3" SQL_ADMIN_PASS='Password123!' ./deploy.sh
```

### All Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `RESOURCE_PREFIX` | `LampApp` | Prefix for all resource names (3-10 chars) |
| `REGION` | `eastus2` | Azure region for deployment |
| `RESOURCE_GROUP` | `${RESOURCE_PREFIX}-rg` | Resource group name |
| `VM_SIZE` | `Standard_B2s` | VM size (2 vCPU, 4 GB RAM) |
| `SSH_KEY_PATH` | `~/.ssh/arpio-lamp-key` | Path to SSH key |
| `SQL_ADMIN_PASS` | _(required)_ | SQL Server admin password (min 8 chars) |

## 📁 Repository Structure

```
.
├── infrastructure/           # Infrastructure as Code
│   ├── main.bicep           # Azure Bicep template (all resources)
│   ├── cloud-init.yml       # VM bootstrap (Apache, PHP, drivers)
│   ├── deploy.sh            # Infrastructure deployment script
│   └── update-vm-only.sh   # Update VM config without full redeploy
│
├── application/             # Application code
│   ├── index.php            # PHP dashboard application
│   └── deploy-app.sh        # Application deployment script
│
└── README.md                # This file
```

## 🔄 Update Application Only

To update the PHP application without touching infrastructure:

1. Edit `application/index.php`
2. Run `cd application && ./deploy-app.sh`

This redeploys the PHP code in ~30 seconds without any infrastructure changes.

## 🔐 SSH Access

```bash
ssh azureuser@<VM_IP> -i ~/.ssh/arpio-lamp-key
```

Replace `<VM_IP>` with the IP shown in deployment output.

## 🧹 Cleanup

Delete all resources:

```bash
az group delete --name LampApp-rg --yes --no-wait
```

(Replace `LampApp-rg` with your resource group name if customized)

## 🏗️ Architecture Notes

### Why Separate Infrastructure from Application?

- **Fast iteration**: Update PHP code without 10-15 min infrastructure redeployment
- **Clean separation**: Infrastructure (Bicep) vs. application (PHP)
- **Independent updates**: Modify dashboard without touching Azure resources

### Why userData Instead of customData?

- **Arpio compatibility**: Arpio translates `userData` during recovery
- `customData` is immutable and not translated
- Application reads config from IMDS userData endpoint

### Recovery-Safe Cloud-Init

Cloud-init no longer creates a placeholder `index.html` on boot. This was removed because Arpio-recovered VMs would re-run cloud-init and overwrite the deployed application with a placeholder page. Now, recovered VMs boot with the application intact from the disk image.

### Network Sandbox Testing

The Application Gateway and Load Balancer allow testing both ingress patterns:
- **Application Gateway**: HTTP/HTTPS routing (Layer 7)
- **Load Balancer**: TCP load balancing with DNAT rules (Layer 4)

Both work with Arpio's Network Sandbox, which blocks outbound traffic but allows inbound through these load balancers.

## 💡 Tips

- **First deployment**: Takes ~10-15 min (Application Gateway is slowest)
- **Application updates**: Takes ~30 seconds
- **Key Vault soft-delete**: If deployment fails with vault name conflict, wait 10 min or use different `RESOURCE_PREFIX`
- **SSH key**: Auto-generated at `~/.ssh/arpio-lamp-key` if not present
- **Passwords**: Use strong passwords for SQL (min 8 chars, mixed case, numbers, symbols)

## 🆘 Troubleshooting

### "Could not get VM IP address"
- Infrastructure not deployed yet
- Run: `cd infrastructure && ./deploy.sh`

### "Connection refused" when accessing URLs
- VM still bootstrapping (wait 2-3 minutes after infrastructure deployment)
- Application not deployed yet (run `./application/deploy-app.sh`)

### Key Vault name conflicts
- Key Vault soft-delete retention (90 days)
- Solution: Use different `RESOURCE_PREFIX` or wait for purge

### SSH connection issues
- Check NSG allows SSH from your IP
- Verify SSH key path: `ls -la ~/.ssh/arpio-lamp-key*`

## 📞 Support

For issues with:
- **Arpio**: Contact Arpio support or check Arpio documentation
- **Azure deployment**: Check Azure Portal > Resource Group > Deployments for errors
- **This repository**: Check deployment output and error messages

---

**Happy Bug Bashing! 🐛🔨**
