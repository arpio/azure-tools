#!/usr/bin/env bash

echo " "
echo "// Stark Industries Mainframe //   J.A.R.V.I.S. online … Hello Mr. Stark!"
echo " "

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

# Password validation function
validate_password() {
  local pwd="$1"
  local len=${#pwd}
  
  # Check length (12-123)
  if [ $len -lt 12 ] || [ $len -gt 123 ]; then
    return 1
  fi
  
  # Count character types
  local count=0
  [[ "$pwd" =~ [a-z] ]] && ((count++))
  [[ "$pwd" =~ [A-Z] ]] && ((count++))
  [[ "$pwd" =~ [0-9] ]] && ((count++))
  [[ "$pwd" =~ [^a-zA-Z0-9] ]] && ((count++))
  
  # Need at least 3 types
  [ $count -ge 3 ]
}

# -------------- PROMPTS --------------
read -p "Enter Resource Group name [rg-arpio-demo]: " RG_INPUT
RESOURCE_GROUP=${RG_INPUT:-rg-arpio-demo}
echo " "

echo "Enter WINDOWS VM admin password"
echo "(The password length must be between 12 and 123. Password must have the 3 of the following: 1 lower case character, 1 upper case character, 1 number and 1 special character)"
while true; do
  read -p "Enter value: " ADMIN_PASSWORD
  echo ""
  if validate_password "$ADMIN_PASSWORD"; then
    break
  else
    echo "Password must contain characters from three of the following four categories: uppercase, lowercase, numbers, and special characters. Please try again."
  fi
done

echo "Enter SQL admin password"
echo "(The password length must be between 12 and 123. Password must have the 3 of the following: 1 lower case character, 1 upper case character, 1 number and 1 special character)"
while true; do
  read -p "Enter value: " SQL_PASSWORD
  echo ""
  if validate_password "$SQL_PASSWORD"; then
    break
  else
    echo "Password must contain characters from three of the following four categories: uppercase, lowercase, numbers, and special characters. Please try again."
  fi
done

#
# -- ensure that the specified VM Size/Sku is available in the specific region
LOCATION="westus2"
VM_SIZE="Standard_B2as_v2"

RAND=$(echo -n "$RESOURCE_GROUP" | md5sum | cut -c1-5)

BICEP_FILE="sqlvm-subscription.bicep"

VM_NAME="starkvm-${RESOURCE_GROUP}"
VM_NAME="${VM_NAME:0:15}"
ADMIN_USER="azureuser"

SQL_ADMIN="sqladmin-$RAND"
SQL_DB="GuestbookDb"
SQL_SERVER="starksql$RAND"


fail() { echo "ERROR: $1" >&2; }
step() { echo "$1"; }

#
# create resources
# TODO: call bicep
az deployment sub create \
  --location "$LOCATION" \
  --template-file "$BICEP_FILE" \
  --name "$RESOURCE_GROUP" \
  --parameters \
    location="$LOCATION" \
    resourceGroupName="$RESOURCE_GROUP" \
    adminUsername="$ADMIN_USER" \
    adminPassword="$ADMIN_PASSWORD" \
    sqlAdminUsername="$SQL_ADMIN" \
    sqlAdminPassword="$SQL_PASSWORD" \
    vmName="$VM_NAME" \
    vmSize="$VM_SIZE" \
    sqlServerName="$SQL_SERVER" 
  
#
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