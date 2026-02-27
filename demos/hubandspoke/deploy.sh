#!/bin/bash

# ============================================
# Azure Hub-Spoke Deployment Script
# ============================================
# Deploys complete hub-spoke architecture with:
# - Hub VNet with Bastion and VPN Gateway
# - App 1 VNet with Load Balancer, VMSS, and Database VM
# - App 2 VNet with Windows VM

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_section() {
    echo -e "\n${BLUE}=== $1 ===${NC}\n"
}

# Check Azure CLI
if ! command -v az &> /dev/null; then
    print_error "Azure CLI is not installed"
    exit 1
fi

# Check login
print_info "Checking Azure CLI login status..."
if ! az account show &> /dev/null; then
    print_warning "Not logged in. Logging in now..."
    az login
fi

print_section "Azure Hub-Spoke Deployment Configuration"

# Subscription
print_info "Available subscriptions:"
az account list --output table --query "[].{Name:name, SubscriptionId:id, State:state}"
echo ""
read -p "Enter Subscription ID (or press Enter for current): " SUBSCRIPTION_ID

if [ -z "$SUBSCRIPTION_ID" ]; then
    SUBSCRIPTION_ID=$(az account show --query id -o tsv)
    print_info "Using current subscription: $SUBSCRIPTION_ID"
else
    az account set --subscription "$SUBSCRIPTION_ID"
    print_info "Set subscription to: $SUBSCRIPTION_ID"
fi

# Resource prefix
echo ""
read -p "Enter resource prefix (e.g., 'arpio-hub'): " RESOURCE_PREFIX
if [ -z "$RESOURCE_PREFIX" ]; then
    print_error "Resource prefix is required"
    exit 1
fi

# Region
print_info "Popular regions: eastus, westus2, centralus, westeurope"
read -p "Enter Azure region: " LOCATION
if [ -z "$LOCATION" ]; then
    print_error "Location is required"
    exit 1
fi

# Admin credentials
echo ""
print_info "VM Administrator Credentials"
read -p "Enter admin username (default: azureuser): " ADMIN_USERNAME
ADMIN_USERNAME=${ADMIN_USERNAME:-azureuser}

read -sp "Enter admin password: " ADMIN_PASSWORD
echo ""
if [ -z "$ADMIN_PASSWORD" ]; then
    print_error "Admin password is required"
    exit 1
fi

# Validate password
if [ ${#ADMIN_PASSWORD} -lt 12 ]; then
    print_error "Password must be at least 12 characters"
    exit 1
fi

# VNet address spaces
echo ""
print_section "Network Configuration"
read -p "Hub VNet prefix (default: 10.0.0.0/16): " HUB_VNET_PREFIX
HUB_VNET_PREFIX=${HUB_VNET_PREFIX:-10.0.0.0/16}

read -p "App 1 VNet prefix (default: 10.1.0.0/16): " APP1_VNET_PREFIX
APP1_VNET_PREFIX=${APP1_VNET_PREFIX:-10.1.0.0/16}

read -p "App 2 VNet prefix (default: 10.2.0.0/16): " APP2_VNET_PREFIX
APP2_VNET_PREFIX=${APP2_VNET_PREFIX:-10.2.0.0/16}

# VM configuration
echo ""
print_section "VM Configuration"
print_info "Common VM sizes:"
print_info "  B-series (Burstable): Standard_B1s, Standard_B2s, Standard_B2ms, Standard_B4ms"
print_info "  D-series (General): Standard_D2s_v3, Standard_D4s_v3, Standard_D8s_v3"
print_info "  E-series (Memory): Standard_E2s_v3, Standard_E4s_v3"
echo ""

read -p "VM Size for all Linux/ARM VMs (default: Standard_B2PS_v2): " VM_SIZE_LINUX
VM_SIZE_LINUX=${VM_SIZE_LINUX:-Standard_B2PS_v2}

read -p "VM Size for all Windows VMs (default: Standard_D2ads_v7): " VM_SIZE_WINDOWS
VM_SIZE_WINDOWS=${VM_SIZE_WINDOWS:-Standard_D2ads_v7}

read -p "VMSS instance count for App1 (default: 2): " VMSS_COUNT
VMSS_COUNT=${VMSS_COUNT:-2}

# PaaS Application option
echo ""
print_section "Optional: PaaS Application Stack"
print_info "You can optionally deploy a standalone PaaS application"
print_info "This includes: App Gateway, App Service, SQL DB, Key Vault, Storage, Container"
print_info "Note: PaaS stack is NOT connected to the hub-spoke VNets"
print_info "Note: SQL Database will use the same admin credentials as the VMs"
echo ""
read -p "Deploy PaaS application? (yes/no, default: no): " DEPLOY_PAAS
DEPLOY_PAAS=${DEPLOY_PAAS:-no}

PAAS_SECRET=""

if [ "$DEPLOY_PAAS" == "yes" ]; then
    echo ""
    print_info "PaaS Application Configuration"
    read -sp "Enter secret value for PaaS Key Vault: " PAAS_SECRET
    echo ""
    
    if [ -z "$PAAS_SECRET" ]; then
        print_error "PaaS secret is required"
        exit 1
    fi
    
    print_info "SQL Database will use VM admin credentials:"
    print_info "  Username: $ADMIN_USERNAME"
    print_info "  Password: (same as VMs)"
fi

# Display summary
print_section "Deployment Summary"
print_info "Subscription: $SUBSCRIPTION_ID"
print_info "Resource Prefix: $RESOURCE_PREFIX"
print_info "Location: $LOCATION"
print_info "Admin Username: $ADMIN_USERNAME"
print_info "Hub VNet: $HUB_VNET_PREFIX"
print_info "App 1 VNet: $APP1_VNET_PREFIX"
print_info "App 2 VNet: $APP2_VNET_PREFIX"
print_info "VM Size (Linux/Arm VMs): $VM_SIZE_LINUX"
print_info "VM Size (Windows VMs): $VM_SIZE_WINDOWS"
print_info "VMSS Instance Count: $VMSS_COUNT"
print_info "Deploy PaaS Application: $DEPLOY_PAAS"
echo ""

print_warning "IMPORTANT: VPN Gateway deployment takes 30-45 minutes!"
if [ "$DEPLOY_PAAS" == "yes" ]; then
    print_warning "Total deployment time with PaaS: 50-65 minutes"
else
    print_warning "Total deployment time: 45-60 minutes"
fi
echo ""

read -p "Proceed with deployment? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    print_warning "Deployment cancelled"
    exit 0
fi

DEPLOYMENT_NAME="${RESOURCE_PREFIX}-deployment-$(date +%Y%m%d-%H%M%S)"

print_section "Starting Deployment"
print_info "Deployment name: $DEPLOYMENT_NAME"
print_info "This will take 45-60 minutes due to VPN Gateway deployment..."

# Build parameters as an array so each value is individually quoted,
# preventing word-splitting on passwords with spaces or special characters
DEPLOY_PARAMS=(
    --parameters "resourcePrefix=$RESOURCE_PREFIX"
    --parameters "location=$LOCATION"
    --parameters "adminUsername=$ADMIN_USERNAME"
    --parameters "adminPassword=$ADMIN_PASSWORD"
    --parameters "hubVnetAddressPrefix=$HUB_VNET_PREFIX"
    --parameters "app1VnetAddressPrefix=$APP1_VNET_PREFIX"
    --parameters "app2VnetAddressPrefix=$APP2_VNET_PREFIX"
    --parameters "vmSizeLinux=$VM_SIZE_LINUX"
    --parameters "vmSizeWindows=$VM_SIZE_WINDOWS"
    --parameters "vmssInstanceCount=$VMSS_COUNT"
)

# Add PaaS parameters if enabled
if [ "$DEPLOY_PAAS" == "yes" ]; then
    DEPLOY_PARAMS+=(
        --parameters "deployPaasApplication=true"
        --parameters "paasSecretValue=$PAAS_SECRET"
    )
fi

# Deploy — placed directly in `if` condition so the error branch is reachable
# even with `set -e` active at the top of the script
if az deployment sub create \
    --name "$DEPLOYMENT_NAME" \
    --location "$LOCATION" \
    --template-file main.bicep \
    "${DEPLOY_PARAMS[@]}" \
    --verbose; then

    print_section "Deployment Successful!"

    # Get outputs
    print_info "Deployment outputs:"
    az deployment sub show \
        --name "$DEPLOYMENT_NAME" \
        --query properties.outputs \
        -o json

    echo ""
    print_info "Resource Groups Created:"
    print_info "  Hub: ${RESOURCE_PREFIX}-hub-rg"
    print_info "  App1: ${RESOURCE_PREFIX}-app1-rg"
    print_info "  App2: ${RESOURCE_PREFIX}-app2-rg"
    if [ "$DEPLOY_PAAS" == "yes" ]; then
        print_info "  PaaS: ${RESOURCE_PREFIX}-paas-rg"
    fi

    echo ""
    print_info "To connect to VMs:"
    print_info "1. Go to Azure Portal"
    print_info "2. Navigate to ${RESOURCE_PREFIX}-hub-rg"
    print_info "3. Find the Bastion resource"
    print_info "4. Use Bastion to connect to any VM"

    echo ""
    print_info "Access App 1 Load Balancer at:"
    LB_IP=$(az deployment sub show --name "$DEPLOYMENT_NAME" --query 'properties.outputs.app1LoadBalancerPublicIp.value' -o tsv)
    if [ -n "$LB_IP" ]; then
        print_info "  http://$LB_IP"
    else
        print_warning "  Load balancer IP not available in deployment outputs"
    fi

    # Show PaaS outputs if deployed
    if [ "$DEPLOY_PAAS" == "yes" ]; then
        echo ""
        print_info "PaaS Application - Access via Application Gateway:"
        PAAS_APPGW_IP=$(az deployment sub show --name "$DEPLOYMENT_NAME" --query 'properties.outputs.paasAppGatewayPublicIp.value' -o tsv 2>/dev/null)

        if [ -n "$PAAS_APPGW_IP" ]; then
            print_info "  App Service (80/443): http://$PAAS_APPGW_IP"
            print_info "  Container Instance (8080): http://$PAAS_APPGW_IP:8080"
            print_warning "  Note: App Service and Container are NOT directly accessible"
        fi
    fi

else
    print_error "Deployment failed. Check error messages above."
    exit 1
fi
