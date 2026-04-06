#!/bin/bash
# =============================================================================
# 🚀 Deploy LAMP Application to Azure VM
# Run this AFTER infrastructure is deployed
# This can be run multiple times to update the application
#
# NOTE: This script is optional and intended for single-VM deployments only.
# For VMSS-compatible deployments, see Seth's lb-server-db-iac demo which
# uses a Bicep-native approach for application deployment.
# =============================================================================

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  Deploy LAMP Application${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# =============================================================================
# Configuration
# =============================================================================
RESOURCE_PREFIX="${RESOURCE_PREFIX:-LampApp}"
RESOURCE_GROUP="${RESOURCE_GROUP:-${RESOURCE_PREFIX}-rg}"
VM_NAME="${VM_NAME:-${RESOURCE_PREFIX}-vm}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/arpio-lamp-key}"

echo -e "${YELLOW}Configuration:${NC}"
echo "  Resource Prefix:   $RESOURCE_PREFIX"
echo "  Resource Group:    $RESOURCE_GROUP"
echo "  VM Name:           $VM_NAME"
echo "  SSH Key:           $SSH_KEY"
echo ""

# =============================================================================
# Step 1: Get VM IP address
# =============================================================================
echo -e "${YELLOW}Step 1: Getting VM IP address...${NC}"
VM_IP=$(az vm show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$VM_NAME" \
  --show-details \
  --query "publicIps" \
  --output tsv)

if [ -z "$VM_IP" ] || [ "$VM_IP" == "null" ]; then
    echo -e "${RED}Error: Could not get VM IP address${NC}"
    echo "  - Is the infrastructure deployed?"
    echo "  - Run: cd infrastructure && ./deploy.sh"
    exit 1
fi

echo -e "${GREEN}✓ VM IP: $VM_IP${NC}"
echo ""

# =============================================================================
# Step 2: Get Load Balancer Resource IDs (for application config)
# =============================================================================
echo -e "${YELLOW}Step 2: Getting load balancer resource IDs...${NC}"

APPGW_ID=$(az network application-gateway show \
  --resource-group "$RESOURCE_GROUP" \
  --name "${RESOURCE_PREFIX}-appgw" \
  --query "id" -o tsv 2>/dev/null || echo "N/A")

LB_ID=$(az network lb show \
  --resource-group "$RESOURCE_GROUP" \
  --name "${RESOURCE_PREFIX}-lb" \
  --query "id" -o tsv 2>/dev/null || echo "N/A")

APPGW_IP=$(az network public-ip show \
  --resource-group "$RESOURCE_GROUP" \
  --name "${RESOURCE_PREFIX}-appgw-pip" \
  --query "ipAddress" -o tsv 2>/dev/null || echo "N/A")

LB_IP=$(az network public-ip show \
  --resource-group "$RESOURCE_GROUP" \
  --name "${RESOURCE_PREFIX}-lb-pip" \
  --query "ipAddress" -o tsv 2>/dev/null || echo "N/A")

echo -e "${GREEN}✓ App Gateway: $APPGW_IP${NC}"
echo -e "${GREEN}✓ Load Balancer: $LB_IP${NC}"
echo ""

# =============================================================================
# Step 3: Create load balancer config file
# =============================================================================
echo -e "${YELLOW}Step 3: Creating application config...${NC}"

cat > /tmp/lb-config.json <<EOF
{
  "appGatewayId": "$APPGW_ID",
  "appGatewayName": "${RESOURCE_PREFIX}-appgw",
  "appGatewayPublicIp": "$APPGW_IP",
  "loadBalancerId": "$LB_ID",
  "loadBalancerName": "${RESOURCE_PREFIX}-lb",
  "loadBalancerPublicIp": "$LB_IP"
}
EOF

echo -e "${GREEN}✓ Config file created${NC}"
echo ""

# =============================================================================
# Step 4: Deploy application files
# =============================================================================
echo -e "${YELLOW}Step 4: Deploying application files to VM...${NC}"

# Copy PHP application
echo "  - Copying index.php..."
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
  index.php azureuser@$VM_IP:/tmp/index.php

# Copy config
echo "  - Copying config..."
scp -i "$SSH_KEY" -o StrictHostKeyChecking=no \
  /tmp/lb-config.json azureuser@$VM_IP:/tmp/lb-config.json

# Install on VM
echo "  - Installing on VM..."
ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no azureuser@$VM_IP <<'ENDSSH'
  # Remove placeholder HTML file (if exists)
  sudo rm -f /var/www/html/index.html

  # Move PHP to web root
  sudo mv /tmp/index.php /var/www/html/index.php
  sudo chmod 644 /var/www/html/index.php
  sudo chown www-data:www-data /var/www/html/index.php

  # Move config
  sudo mv /tmp/lb-config.json /etc/arpio-lamp/lb-config.json
  sudo chmod 644 /etc/arpio-lamp/lb-config.json

  # Restart Apache
  sudo systemctl restart apache2

  echo "✓ Application installed successfully"
ENDSSH

echo -e "${GREEN}✓ Application deployed${NC}"
echo ""

# =============================================================================
# Step 5: Display results
# =============================================================================
echo ""
echo -e "${GREEN}================================================${NC}"
echo -e "${GREEN}  ✅ Application Deployment Complete!${NC}"
echo -e "${GREEN}================================================${NC}"
echo ""
echo -e "${BLUE}🌐 Access your application:${NC}"
echo "  Direct VM:         http://$VM_IP"
[ "$APPGW_IP" != "N/A" ] && echo "  App Gateway:       http://$APPGW_IP"
[ "$LB_IP" != "N/A" ] && echo "  Load Balancer:     http://$LB_IP"
echo ""
echo -e "${BLUE}💡 Tips:${NC}"
echo "  - To update the application, edit index.php and run this script again"
echo "  - Takes ~30 seconds to deploy application updates"
echo "  - No infrastructure changes needed for app updates"
echo ""
echo -e "${GREEN}================================================${NC}"
