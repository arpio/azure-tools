#!/bin/bash
# =============================================================================
# 🚀 Azure LAMP Stack Infrastructure Deployment
# Deploys: VNet, VM, Application Gateway, Load Balancer, SQL, Key Vault, Storage
# =============================================================================

set -e  # Exit on any error

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  Arpio Bug Bash — Infrastructure Deployment${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# =============================================================================
# Configuration (customize these via environment variables)
# =============================================================================
RESOURCE_PREFIX="${RESOURCE_PREFIX:-LampApp}"
REGION="${REGION:-eastus2}"
RESOURCE_GROUP="${RESOURCE_GROUP:-${RESOURCE_PREFIX}-rg}"
VM_SIZE="${VM_SIZE:-Standard_B2s}"
SSH_KEY_PATH="${SSH_KEY_PATH:-$HOME/.ssh/arpio-lamp-key}"

echo -e "${YELLOW}Configuration:${NC}"
echo "  Resource Prefix:  $RESOURCE_PREFIX"
echo "  Region:           $REGION"
echo "  Resource Group:   $RESOURCE_GROUP"
echo "  VM Size:          $VM_SIZE"
echo ""

# =============================================================================
# Step 1: Set Azure subscription
# =============================================================================
echo -e "${YELLOW}Step 1: Setting Azure subscription${NC}"
az account show --query "{Subscription:name, ID:id}" -o table
echo -e "${GREEN}✓ Using current subscription${NC}"
echo ""

# =============================================================================
# Step 2: Create Resource Group
# =============================================================================
echo -e "${YELLOW}Step 2: Creating Resource Group${NC}"
az group create --name "$RESOURCE_GROUP" --location "$REGION" --output table
echo -e "${GREEN}✓ Resource Group created in $REGION${NC}"
echo ""

# =============================================================================
# Step 3: Ensure SSH key exists
# =============================================================================
echo -e "${YELLOW}Step 3: Checking SSH key${NC}"
if [ ! -f "$SSH_KEY_PATH.pub" ]; then
    echo "SSH key not found. Creating new key pair..."
    ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -C "arpio-lamp-key"
    echo -e "${GREEN}✓ Created new SSH key at $SSH_KEY_PATH${NC}"
else
    echo -e "${GREEN}✓ Using existing SSH key at $SSH_KEY_PATH${NC}"
fi
SSH_KEY=$(cat "$SSH_KEY_PATH.pub")
echo ""

# =============================================================================
# Step 4: Get SQL admin password
# =============================================================================
echo -e "${YELLOW}Step 4: SQL admin password${NC}"
if [ -z "$SQL_ADMIN_PASS" ]; then
    echo ""
    read -sp "Enter SQL Admin Password (min 8 chars): " SQL_ADMIN_PASS
    echo ""
    if [ ${#SQL_ADMIN_PASS} -lt 8 ]; then
        echo -e "${RED}Error: Password must be at least 8 characters${NC}"
        exit 1
    fi
fi
echo -e "${GREEN}✓ SQL password provided${NC}"
echo ""

# =============================================================================
# Step 5: Deploy Bicep template
# =============================================================================
echo -e "${YELLOW}Step 5: Deploying infrastructure...${NC}"
echo "This creates: VNet, NSG, Public IPs, NIC, VM, App Gateway, Load Balancer, SQL, Key Vault, Storage"
echo "Estimated time: 10-15 minutes (Application Gateway takes ~5-10 min)"
echo ""

az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file main.bicep \
  --parameters \
    resourcePrefix="$RESOURCE_PREFIX" \
    location="$REGION" \
    vmSize="$VM_SIZE" \
    vmAdminSshPublicKey="$SSH_KEY" \
    sqlAdminPassword="$SQL_ADMIN_PASS" \
  --query "properties.outputs" \
  --output json > deployment-outputs.json

if [ $? -ne 0 ]; then
    echo -e "${RED}✗ Deployment failed${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Infrastructure deployment complete${NC}"
echo ""

# =============================================================================
# Step 6: Parse and display outputs
# =============================================================================
function get_output() {
    jq -r ".$1.value // \"N/A\"" deployment-outputs.json
}

VM_IP=$(get_output vmPublicIp)
WEB_URL=$(get_output webUrl)
APPGW_URL=$(get_output appGatewayUrl)
LB_URL=$(get_output loadBalancerUrl)
SQL_SERVER=$(get_output sqlServerFqdn)
KV_NAME=$(get_output keyVaultName)
STORAGE_NAME=$(get_output storageAccountName)

# =============================================================================
# Step 6.5: Upload Arpio logo to blob storage
# =============================================================================
echo -e "${YELLOW}Step 6.5: Uploading assets to blob storage...${NC}"
az storage blob upload \
  --account-name "$STORAGE_NAME" \
  --container-name assets \
  --name arpio-logo.svg \
  --file ../assets/arpio-logo.svg \
  --auth-mode login \
  --overwrite \
  --output none

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Logo uploaded to blob storage${NC}"
else
    echo -e "${YELLOW}⚠ Warning: Logo upload failed (non-critical)${NC}"
fi
echo ""

# =============================================================================
# Step 7: Display summary
# =============================================================================
echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  ✅ Infrastructure Deployment Complete!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "${BLUE}📦 Deployed Resources:${NC}"
echo "  Resource Group:    $RESOURCE_GROUP"
echo "  VM Public IP:      $VM_IP"
echo "  SQL Server:        $SQL_SERVER"
echo "  Key Vault:         $KV_NAME"
echo "  Storage Account:   $STORAGE_NAME"
echo ""
echo -e "${BLUE}🌐 Access URLs (Infrastructure Ready):${NC}"
echo "  VM Direct:         $WEB_URL"
echo "  App Gateway:       $APPGW_URL"
echo "  Load Balancer:     $LB_URL"
echo ""
echo -e "${YELLOW}⚠️  Note: Application not yet deployed${NC}"
echo -e "${YELLOW}   Run: ../application/deploy-app.sh to deploy the PHP application${NC}"
echo ""
echo -e "${BLUE}🔐 SSH Access:${NC}"
echo "  ssh azureuser@$VM_IP -i $SSH_KEY_PATH"
echo ""
echo -e "${GREEN}================================================${NC}"
