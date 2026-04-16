#!/usr/bin/env bash
# =============================================================================
# AKS DEMO – EASY CLUSTER DEPLOY
# =============================================================================
# Azure equivalent of the EKS demo's ez_cluster_deploy.sh.
# Deploys a complete AKS cluster with:
#   • VNet + subnets + NAT Gateway
#   • AKS cluster (system + user node pools, built-in autoscaler)
#   • nginx Ingress Controller (Azure Load Balancer)
#   • Azure Disk persistent storage (StorageClass + PVC)
#   • Workload Identity (equivalent to EKS IRSA)
#   • Cosmos DB (NoSQL) – equivalent to DynamoDB
#   • Azure Key Vault secrets via CSI driver – equivalent to Secrets Manager
#   • Guestbook demo application
#
# Prerequisites:
#   • Azure CLI  (az)   – https://docs.microsoft.com/en-us/cli/azure/install-azure-cli
#   • Helm              – https://helm.sh/docs/intro/install/
#   • kubectl           – https://kubernetes.io/docs/tasks/tools/
#   • Bicep CLI         – bundled with Azure CLI >= 2.20  (az bicep install)
#
# Usage:
#   cd scripts
#   ./ez_cluster_deploy.sh
# =============================================================================

set -euo pipefail

# Prevent Git Bash on Windows from converting Unix-style paths (e.g.
# /subscriptions/...) to Windows paths (C:/Program Files/Git/subscriptions/...)
# when they are passed as Azure CLI arguments.
export MSYS_NO_PATHCONV=1

# ── Helpers ───────────────────────────────────────────────────────────────────


# ── Banner ─────────────────────────────────────────────────────────────────────

echo ""
echo "============================================="
echo "😎  Let's create an Azure AKS Cluster !!!"
echo "============================================="
echo ""

# ── Prerequisites check ───────────────────────────────────────────────────────

for tool in az helm kubectl jq; do
  if ! command -v "$tool" &>/dev/null; then
    echo "❌ '$tool' is not installed. Please install it and try again."
    exit 1
  fi
done

# Ensure Bicep is available (bundled in Azure CLI but needs a one-time install)
if ! az bicep version &>/dev/null; then
  echo "📦 Installing Bicep CLI..."
  az bicep install
fi

# ── Find repo root ────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
BICEP_DIR="$REPO_DIR/bicep"

# Convert BICEP_DIR to a Windows path so the Azure CLI can resolve --template-file
# correctly. MSYS_NO_PATHCONV=1 (above) stops automatic conversion, so we do it
# explicitly here. SCRIPT_DIR is left as a Unix path — it's only passed to bash.
if command -v cygpath &>/dev/null; then
  BICEP_DIR="$(cygpath -w "$BICEP_DIR")"
fi

# ── Gather inputs ─────────────────────────────────────────────────────────────

echo "Checking Azure login..."
if ! az account show &>/dev/null; then
  echo "🫵 Not logged in to Azure. Running 'az login'..."
  az login
fi

# Subscription
echo ""
echo "Available subscriptions:"
az account list --output table --query "[].{Name:name, SubscriptionId:id, State:state}"
echo ""
read -p "Enter Subscription ID (or press Enter for current): " SUBSCRIPTION_ID

if [[ -z "$SUBSCRIPTION_ID" ]]; then
  SUBSCRIPTION_ID=$(az account show --query id --output tsv)
else
  if [[ ! "$SUBSCRIPTION_ID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "❌ '$SUBSCRIPTION_ID' is not a valid subscription ID (expected xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)."
    exit 1
  fi
  az account set --subscription "$SUBSCRIPTION_ID"
fi

SUBSCRIPTION_NAME=$(az account show --query name --output tsv)

# Environment
ENV_DIR="$BICEP_DIR/environment"
ENV_FILES=($(ls -1 "$ENV_DIR"/*.env 2>/dev/null))

if [[ ${#ENV_FILES[@]} -eq 0 ]]; then
  echo "❌ No .env files found in $ENV_DIR. Please add environment files and try again."
  exit 1
fi

echo ""
echo "Available environments:"
for i in "${!ENV_FILES[@]}"; do
  echo "  $((i+1)). ${ENV_FILES[$i]##*/}"
done

printf "Select a number: "
read -r choice

if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#ENV_FILES[@]} )); then
  echo "❌ Invalid selection."
  exit 1
fi

ENV_FILE="${ENV_FILES[$((choice-1))]}"

# shellcheck source=/dev/null
source "$ENV_FILE"

for var in ENV_NAME AZURE_REGION VM_SIZE KUBERNETES_VERSION; do
  if [[ -z "${!var:-}" ]]; then
    echo "❌ Variable '$var' is not set in $ENV_FILE"
    exit 1
  fi
done

# Resource prefix
echo ""
read -p "Enter resource prefix (e.g. 'arpio'): " RESOURCE_PREFIX
if [[ -z "$RESOURCE_PREFIX" ]]; then
  echo "❌ Resource prefix is required."
  exit 1
fi
if [[ ! "$RESOURCE_PREFIX" =~ ^[a-zA-Z][a-zA-Z0-9-]*$ ]]; then
  echo "❌ Prefix must start with a letter and contain only letters, numbers, or hyphens."
  exit 1
fi

# ── Derive resource names (must match Bicep locals) ────────────────────────────

PREFIX="$RESOURCE_PREFIX"
PREFIX_ENV="${PREFIX}-${ENV_NAME}"
RESOURCE_GROUP="${PREFIX_ENV}-rg"
CLUSTER_NAME="${PREFIX_ENV}-cluster"

# ── Confirm ────────────────────────────────────────────────────────────────────

echo ""
echo "================================="
echo "        Deployment Summary"
echo "================================="
echo "  Subscription : $SUBSCRIPTION_NAME"
echo "  Sub ID       : $SUBSCRIPTION_ID"
echo "  Environment  : $ENV_NAME"
echo "  Region       : $AZURE_REGION"
echo "  Prefix       : $PREFIX"
echo "  Resource Group: $RESOURCE_GROUP"
echo "  Cluster      : $CLUSTER_NAME"
echo "  K8s Version  : $KUBERNETES_VERSION"
echo "  VM Size      : $VM_SIZE"
echo "================================="
echo ""
echo "👀 Ensure this is NOT a production subscription and has no live workloads."
echo ""
printf "Proceed with deployment? [y/n]: "
read -r response
if [[ ! "$response" =~ ^[Yy]([Ee][Ss])?$ ]]; then
  echo "👋 Good bye!"
  exit 1
fi

# ── Create resource group ─────────────────────────────────────────────────────

echo ""
echo "========================="
echo "📦 Creating resource group '$RESOURCE_GROUP'..."
az group create \
  --name     "$RESOURCE_GROUP" \
  --location "$AZURE_REGION" \
  --output   none

# ── Step 00 – Backend Storage ─────────────────────────────────────────────────
# Deployed via Bicep so uniqueString(resourceGroup().id) generates a
# globally unique, deterministic storage account name.

BE_CONTAINER="bicep-state"

echo ""
echo "========================="
echo "🚀 Step 00: Provisioning backend storage..."

BE_OUTPUT=$(az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file  "$BICEP_DIR/00_backend.bicep" \
  --name           "00-backend" \
  --output         json)

BE_SA=$(echo "$BE_OUTPUT" | jq -r '.properties.outputs.storageAccountName.value')
echo "✅ Backend storage ready: ${BE_SA}/${BE_CONTAINER}"

# ── Step 01 – Infrastructure (VNet + AKS + Cosmos DB) ────────────────────────

echo ""
echo "========================="
echo "🚀 Step 01: Deploying infrastructure (VNet, AKS, Cosmos DB)..."

# Deploy the infrastructure Bicep file
# az deployment group create is the equivalent of terraform apply
INFRA_OUTPUT=$(az deployment group create \
  --resource-group     "$RESOURCE_GROUP" \
  --template-file      "$BICEP_DIR/01_infrastructure.bicep" \
  --parameters         envName="$ENV_NAME" \
                       prefix="$PREFIX" \
                       location="$AZURE_REGION" \
                       kubernetesVersion="$KUBERNETES_VERSION" \
                       vmSize="$VM_SIZE" \
  --name               "01-infrastructure-${ENV_NAME}" \
  --output             json)

# Extract outputs – equivalent to Terraform output values
AKS_NAME=$(echo "$INFRA_OUTPUT"       | jq -r '.properties.outputs.aksClusterName.value')
OIDC_URL=$(echo "$INFRA_OUTPUT"       | jq -r '.properties.outputs.oidcIssuerUrl.value')
COSMOS_ENDPOINT=$(echo "$INFRA_OUTPUT"| jq -r '.properties.outputs.cosmosEndpoint.value')
COSMOS_ACCOUNT=$(echo "$INFRA_OUTPUT" | jq -r '.properties.outputs.cosmosAccountName.value')
COSMOS_DB=$(echo "$INFRA_OUTPUT"      | jq -r '.properties.outputs.cosmosDatabaseName.value')
COSMOS_CTR=$(echo "$INFRA_OUTPUT"     | jq -r '.properties.outputs.cosmosContainerName.value')

echo "✅ Infrastructure deployed. AKS cluster: $AKS_NAME"

# ── Wait for AKS cluster to be fully ready ────────────────────────────────────
# az deployment group create returns when the control plane is up, but node pools,
# CoreDNS, RBAC role bindings, and webhook admission controllers are still
# initializing. Running kubectl too soon causes transient forbidden errors.
# Equivalent to dataplane_wait_duration = "60s" in the EKS demo — but we wait
# for the actual node pool Ready condition rather than a fixed sleep.
# See docs/separate_configs.md for a deeper discussion of this pattern.
echo "⏳ Waiting for AKS node pools to be ready..."
az aks wait \
  --resource-group "$RESOURCE_GROUP" \
  --name           "$AKS_NAME" \
  --updated \
  --interval       15 \
  --timeout        600
echo "✅ AKS cluster is ready."

# ── Step 02 – Ingress Controller ──────────────────────────────────────────────

echo ""
echo "========================="
echo "🚀 Step 02: Installing nginx Ingress Controller..."
bash "$SCRIPT_DIR/02_ingress_controller.sh" "$RESOURCE_GROUP" "$AKS_NAME"

# ── Step 03 – Storage ─────────────────────────────────────────────────────────

echo ""
echo "========================="
echo "🚀 Step 03: Configuring persistent storage (Azure Disk CSI)..."
bash "$SCRIPT_DIR/03_storage.sh" "$RESOURCE_GROUP" "$AKS_NAME"

# ── Step 04 – Authentication (Workload Identity) ──────────────────────────────

echo ""
echo "========================="
echo "🚀 Step 04: Setting up Workload Identity..."

COSMOS_RESOURCE_ID=$(az cosmosdb show \
  --resource-group "$RESOURCE_GROUP" \
  --name           "$COSMOS_ACCOUNT" \
  --query          id \
  --output         tsv)

DEPLOYER_OBJECT_ID=$(az ad signed-in-user show --query id --output tsv 2>/dev/null \
  || az account show --query user.name --output tsv)

AUTH_OUTPUT=$(az deployment group create \
  --resource-group     "$RESOURCE_GROUP" \
  --template-file      "$BICEP_DIR/04_authentication.bicep" \
  --parameters         prefixEnv="$PREFIX_ENV" \
                       location="$AZURE_REGION" \
                       oidcIssuerUrl="$OIDC_URL" \
                       cosmosAccountId="$COSMOS_RESOURCE_ID" \
                       cosmosAccountName="$COSMOS_ACCOUNT" \
  --name               "04-authentication-${ENV_NAME}" \
  --output             json)

APP_IDENTITY_CLIENT_ID=$(echo "$AUTH_OUTPUT" | jq -r '.properties.outputs.appIdentityClientId.value')
APP_IDENTITY_PRINCIPAL_ID=$(echo "$AUTH_OUTPUT" | jq -r '.properties.outputs.appIdentityPrincipalId.value')

echo "✅ Workload Identity configured. App identity client ID: $APP_IDENTITY_CLIENT_ID"

# ── Step 06 – Key Vault ───────────────────────────────────────────────────────

echo ""
echo "========================="
echo "🚀 Step 06: Deploying Key Vault and secrets..."

KV_OUTPUT=$(az deployment group create \
  --resource-group     "$RESOURCE_GROUP" \
  --template-file      "$BICEP_DIR/06_key_vault.bicep" \
  --parameters         prefixEnv="$PREFIX_ENV" \
                       location="$AZURE_REGION" \
                       deployerObjectId="$DEPLOYER_OBJECT_ID" \
                       appIdentityPrincipalId="$APP_IDENTITY_PRINCIPAL_ID" \
  --name               "06-keyvault-${ENV_NAME}" \
  --output             json)

KV_NAME=$(echo "$KV_OUTPUT"    | jq -r '.properties.outputs.keyVaultName.value')
SECRET_NAME=$(echo "$KV_OUTPUT"| jq -r '.properties.outputs.secretName.value')
TENANT_ID=$(echo "$KV_OUTPUT"  | jq -r '.properties.outputs.tenantId.value')

echo "✅ Key Vault deployed: $KV_NAME"

# ── Step 05 – Application ────────────────────────────────────────────────────
# Note: runs after auth (04) and key vault (06) because it depends on both.
# Same ordering logic as the EKS demo (application.tf depends_on eks + secrets).

echo ""
echo "========================="
echo "🚀 Step 05: Deploying guestbook application..."
bash "$SCRIPT_DIR/05_application.sh" \
  "$RESOURCE_GROUP" \
  "$AKS_NAME" \
  "$APP_IDENTITY_CLIENT_ID" \
  "$COSMOS_ENDPOINT" \
  "$COSMOS_DB" \
  "$COSMOS_CTR" \
  "$AZURE_REGION" \
  "$KV_NAME" \
  "$TENANT_ID" \
  "$SECRET_NAME"

# ── Get the app URL ───────────────────────────────────────────────────────────
# Equivalent to the EKS demo's ALB DNS name retrieval at the end of the script.

echo ""
echo "=========================="
echo -n "🔄 Getting ingress IP. Please stand by"
for i in $(seq 1 12); do
  echo -n "."
  sleep 5
  INGRESS_IP=$(kubectl get svc ingress-nginx-controller \
    --namespace ingress-nginx \
    --output jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "$INGRESS_IP" ]]; then
    break
  fi
done
echo ""

if [[ -z "$INGRESS_IP" ]]; then
  echo "⏳ The URL for your application is not ready yet."
  echo "   Run this to check: kubectl get svc -n ingress-nginx"
else
  echo "⭐️  Here is the URL of your newly deployed application running on AKS:"
  echo "💻     http://${INGRESS_IP}    "
  echo "⏳ Please be patient. It may take up to a minute to become available."
fi

echo ""
echo "🔑 To configure kubectl:"
echo "   az aks get-credentials --resource-group $RESOURCE_GROUP --name $AKS_NAME"
echo ""
echo "🌐 Azure Portal – Resource Group:"
PORTAL_BASE="https://portal.azure.com/#resource/subscriptions/${SUBSCRIPTION_ID}/resourceGroups"
echo "   ${PORTAL_BASE}/${RESOURCE_GROUP}/overview"
echo ""
echo "✅ Deployment complete!"
