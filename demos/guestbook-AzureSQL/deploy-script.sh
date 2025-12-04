echo ""
echo "// Stark Industries Mainframe //   J.A.R.V.I.S. online … Hello Mr. Stark!"
echo ""

# ================================================================
# Arpio Demo Deployment Script (Super Duper Edition)
# Creates:
#   - Resource Group (prompted)
#   - VNet/Subnet/NSG/NIC/Public IP
#   - Azure SQL Server + Database
#   - Windows Server VM (Win2022) + IIS
#   - Guestbook table (via sqlcmd, with warm-up loop)
#   - Key Vault + secrets + RBAC for VM to read secrets
#   - creation location is eastus2 / I kept having throttling issues in eastus1
# ================================================================

# -------------- PROMPTS --------------
read -p "Enter Resource Group name [rg-arpio-demo]: " RG_INPUT
RESOURCE_GROUP=${RG_INPUT:-rg-arpio-demo}

read -s -p "Enter WINDOWS VM admin password (The password length must be between 12 and 123. Password must have the 3 of the following: 1 lower case character, 1 upper case character, 1 number and 1 special character): " ADMIN_PASSWORD
echo ""
read -s -p "Enter SQL admin password: " SQL_PASSWORD
echo ""

LOCATION="eastus2"

RAND=$RANDOM

VM_NAME="starkvm-$RAND"
ADMIN_USER="azureuser"

SQL_ADMIN="sqladmin"
SQL_DB="GuestbookDb"
SQL_SERVER="starksql$RAND"

VNET_NAME="stark-vnet-$RAND"
SUBNET_NAME="stark-subnet"
IP_NAME="stark-public-ip-$RAND"
NIC_NAME="stark-nic-$RAND"
NSG_NAME="stark-nsg-$RAND"
KV_NAME="stark-kv-$RAND"

fail() { echo "ERROR: $1" >&2; }
step() { echo "$1"; }

# --------- Networking Infrastructure ---------
step "Creating resource group..."
az group create -n "$RESOURCE_GROUP" -l "$LOCATION" >/dev/null || fail "resource group create failed"

# --------- Register Key Vault Provider ---------
step "Registering Microsoft.KeyVault provider..."
az provider register --namespace Microsoft.KeyVault >/dev/null 2>&1 || fail "KeyVault provider register command failed"

step "Checking Microsoft.KeyVault registration state..."
STATE=""
for i in {1..20}; do
  STATE=$(az provider show --namespace Microsoft.KeyVault --query "registrationState" -o tsv 2>/dev/null || echo "")
  if [ "$STATE" == "Registered" ]; then
    step "KeyVault provider is registered."
    break
  fi
  step "KeyVault provider state: $STATE (attempt $i)... waiting..."
  sleep 6
done
[ "$STATE" != "Registered" ] && fail "KeyVault provider did not reach 'Registered' state (continuing anyway)"

# --------- VNet / IP / NSG / NIC ---------
step "Creating virtual network..."
az network vnet create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VNET_NAME" \
  --address-prefix 10.0.0.0/16 \
  --subnet-name "$SUBNET_NAME" \
  --subnet-prefix 10.0.1.0/24 >/dev/null || fail "vnet create failed"

step "Creating public IP..."
az network public-ip create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$IP_NAME" \
  --sku Standard \
  --location "$LOCATION" >/dev/null || fail "public IP create failed"

step "Creating network security group..."
az network nsg create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$NSG_NAME" >/dev/null || fail "nsg create failed"

step "Allowing RDP..."
az network nsg rule create \
  --resource-group "$RESOURCE_GROUP" \
  --nsg-name "$NSG_NAME" \
  --name Allow-RDP \
  --priority 1000 \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 3389 >/dev/null || fail "nsg rule RDP failed"

step "Allowing HTTP..."
az network nsg rule create \
  --resource-group "$RESOURCE_GROUP" \
  --nsg-name "$NSG_NAME" \
  --name Allow-HTTP \
  --priority 1001 \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 80 >/dev/null || fail "nsg rule HTTP failed"

step "Creating NIC..."
az network nic create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$NIC_NAME" \
  --vnet-name "$VNET_NAME" \
  --subnet "$SUBNET_NAME" \
  --network-security-group "$NSG_NAME" \
  --public-ip-address "$IP_NAME" >/dev/null || fail "nic create failed"

# --------- Azure SQL ---------
step "Creating Azure SQL Server..."
az sql server create \
  --name "$SQL_SERVER" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --admin-user "$SQL_ADMIN" \
  --admin-password "$SQL_PASSWORD" >/dev/null || fail "sql server create failed"

step "Creating SQL firewall rule (allow Azure services)..."
az sql server firewall-rule create \
  --resource-group "$RESOURCE_GROUP" \
  --server "$SQL_SERVER" \
  --name AllowAzure \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 0.0.0.0 >/dev/null || fail "sql firewall rule failed"

step "Creating Azure SQL Database..."
az sql db create \
  --resource-group "$RESOURCE_GROUP" \
  --server "$SQL_SERVER" \
  --name "$SQL_DB" \
  --service-objective Basic >/dev/null || fail "sql db create failed"

# --------- VM ---------
step "Creating Windows VM..."
az vm create \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --location "$LOCATION" \
  --nics "$NIC_NAME" \
  --image Win2022Datacenter \
  --admin-username "$ADMIN_USER" \
  --admin-password "$ADMIN_PASSWORD" \
  --assign-identity \
  --size Standard_B2s \
  --public-ip-sku Standard >/dev/null || fail "vm create failed"

# Install IIS (simple extension call; if it fails we still continue)
step "Installing IIS on VM..."
az vm extension set \
  --resource-group "$RESOURCE_GROUP" \
  --vm-name "$VM_NAME" \
  --publisher Microsoft.Compute \
  --name CustomScriptExtension \
  --version 1.10 \
  --settings "{\"commandToExecute\":\"powershell -NoProfile -ExecutionPolicy Bypass -Command Install-WindowsFeature Web-Server,Web-Asp-Net45,Web-Net-Ext45\"}" \
  >/dev/null \
  || fail "IIS extension install failed (VM is still usable… you might want to think about destroying and restart"

# --------- Key Vault + Secrets + RBAC ---------
step "Creating Key Vault..."
az keyvault create \
  --name "$KV_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --location "$LOCATION" \
  --enable-rbac-authorization true >/dev/null || fail "key vault create failed"

step "Storing SQL admin password in Key Vault..."
az keyvault secret set \
  --vault-name "$KV_NAME" \
  --name sql-admin-password \
  --value "$SQL_PASSWORD" >/dev/null || fail "key vault secret set (sql-admin-password) failed"

step "Storing VM admin password in Key Vault..."
az keyvault secret set \
  --vault-name "$KV_NAME" \
  --name vm-admin-password \
  --value "$ADMIN_PASSWORD" >/dev/null || fail "key vault secret set (vm-admin-password) failed"

step "Assigning 'Key Vault Secrets User' role to VM managed identity..."
PRINCIPAL_ID=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --query identity.principalId -o tsv 2>/dev/null || echo "")

if [ -z "$PRINCIPAL_ID" ]; then
  fail "Could not obtain VM managed identity principalId"
else
  KV_ID=$(az keyvault show \
    --name "$KV_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query id -o tsv 2>/dev/null || echo "")

  if [ -z "$KV_ID" ]; then
    fail "Could not obtain Key Vault resource id"
  else
    az role assignment create \
      --role "Key Vault Secrets User" \
      --assignee "$PRINCIPAL_ID" \
      --scope "$KV_ID" >/dev/null || fail "role assignment create failed"
  fi
fi

# --------- Create Guestbook table from Cloud Shell ---------
step "Creating Guestbook table from Cloud Shell..."

# Ensure sqlcmd exists; if not, try to install (same behavior as original script)
if ! command -v sqlcmd >/dev/null 2>&1; then
  step "sqlcmd not found, attempting to install mssql-tools..."
  sudo apt-get update -y >/dev/null 2>&1
  sudo ACCEPT_EULA=Y apt-get install -y mssql-tools unixodbc-dev >/dev/null 2>&1 \
    || fail "sqlcmd install failed; table creation will need manual step"
  export PATH="$PATH:/opt/mssql-tools/bin"
fi

SQL_FQDN="${SQL_SERVER}.database.windows.net"

CREATE_SQL="
IF OBJECT_ID('dbo.Guestbook','U') IS NULL
BEGIN
  CREATE TABLE dbo.Guestbook (
    Id INT IDENTITY(1,1) PRIMARY KEY,
    Entry NVARCHAR(400),
    Created DATETIME NOT NULL DEFAULT GETDATE()
  );
END
"

# Retry loop for Azure SQL warm-up
TABLE_OK=0
for i in {1..18}; do
  sqlcmd -S "$SQL_FQDN" -d "$SQL_DB" -U "$SQL_ADMIN" -P "$SQL_PASSWORD" -Q "$CREATE_SQL" >/dev/null 2>&1
  RC=$?
  if [ $RC -eq 0 ]; then
    TABLE_OK=1
    break
  fi
  step "Waiting for Azure SQL to be ready... attempt $i"
  sleep 10
done

if [ $TABLE_OK -ne 1 ]; then
  fail "Guestbook table creation failed after retries; DB exists, you can create the table later. (or destroy now)"
fi

# --------- Outputs ---------
VM_IP=$(az network public-ip show -g "$RESOURCE_GROUP" -n "$IP_NAME" --query ipAddress -o tsv 2>/dev/null || echo "")
CONNSTR="Server=tcp:${SQL_FQDN},1433;Initial Catalog=${SQL_DB};User ID=${SQL_ADMIN};Password=${SQL_PASSWORD};Encrypt=True;"

echo ""
echo "======================================================"
echo "Deployment Complete - ALL HAIL HYDRA !!!!"
echo "======================================================"
echo "VM URL: http://$VM_IP"
echo ""
echo "RDP Information:"
echo "IP Address: $VM_IP"
echo "Username: $ADMIN_USER"
echo "Password: $ADMIN_PASSWORD"
echo "mstsc /v:$VM_IP"
echo ""
echo "SQL Connection String:"
echo "$CONNSTR"
echo ""
echo "Key Vault Name: $KV_NAME"
echo "======================================================"