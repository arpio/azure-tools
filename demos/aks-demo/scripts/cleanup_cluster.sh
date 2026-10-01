#!/usr/bin/env bash
# =============================================================================
# AKS DEMO – CLUSTER CLEANUP
# =============================================================================
# Azure equivalent of the EKS demo's cleanup_cluster.sh.
# Destroys all resources created by ez_cluster_deploy.sh.
#
# Teardown order (mirrors EKS demo cleanup.md rationale):
#   1. Delete the Kubernetes Deployment  (lets the cluster clean up pods)
#   2. Delete the PersistentVolumeClaim  (lets the CSI driver detach the disk)
#   3. Delete Azure resource group       (removes AKS, VNet, Cosmos DB, Key Vault)
#
# Why this order?
#   Same reason as the EKS demo: if you delete the cluster before the PVC,
#   the CSI driver never gets a chance to detach and delete the Managed Disk,
#   leaving an orphaned disk in your subscription.
#
# Usage:
#   ./cleanup_cluster.sh -env-file=<path-to-.env-file>
#   ./cleanup_cluster.sh -env-file=../bicep/environment/eastus.env
# =============================================================================

set -euo pipefail

# Prevent Git Bash on Windows from converting Unix-style paths (e.g.
# /subscriptions/...) to Windows paths (C:/Program Files/Git/subscriptions/...)
# when they are passed as Azure CLI arguments.
export MSYS_NO_PATHCONV=1

# ── Parse arguments ───────────────────────────────────────────────────────────

ENV_FILE=""

for arg in "$@"; do
  if [[ "$arg" =~ ^-env-file=(.*)$ ]]; then
    ENV_FILE="${BASH_REMATCH[1]}"
  fi
done

if [[ -z "$ENV_FILE" ]]; then
  echo "Usage: $0 -env-file=<path-to-.env>"
  echo "  e.g. $0 -env-file=../bicep/environment/eastus.env"
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "❌ Environment file not found: $ENV_FILE"
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

for var in ENV_NAME AZURE_REGION; do
  if [[ -z "${!var:-}" ]]; then
    echo "❌ Variable '$var' is not set in $ENV_FILE"
    exit 1
  fi
done

# ── Derive names ──────────────────────────────────────────────────────────────

PREFIX_ENV="aks-demo-${ENV_NAME}"
RESOURCE_GROUP="${PREFIX_ENV}-rg"
CLUSTER_NAME="${PREFIX_ENV}-cluster"
APP_NAME="guestbook-${PREFIX_ENV}"

# ── Check login / select subscription ────────────────────────────────────────

if ! az account show &>/dev/null; then
  echo "🫵 Not logged in to Azure. Running 'az login'..."
  az login
fi

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

echo ""
echo "✅ Selected environment: [$ENV_NAME]"
echo "💣 The following will be PERMANENTLY DESTROYED in subscription [$SUBSCRIPTION_NAME]:"
echo "   • Kubernetes Deployment: ${APP_NAME}-deployment"
echo "   • Kubernetes PVC: azure-disk-pv-claim"
echo "   • Resource Group: $RESOURCE_GROUP  (ALL resources inside it)"
echo ""
printf "Are you SURE? [y/n]: "
read -r response
if [[ ! "$response" =~ ^[Yy]([Ee][Ss])?$ ]]; then
  echo "👋 Cleanup cancelled."
  exit 1
fi

# ── Configure kubectl ─────────────────────────────────────────────────────────

echo "🔧 Configuring kubectl..."
if az aks show --resource-group "$RESOURCE_GROUP" --name "$CLUSTER_NAME" &>/dev/null; then
  az aks get-credentials \
    --resource-group "$RESOURCE_GROUP" \
    --name           "$CLUSTER_NAME" \
    --overwrite-existing

  # ── Step 1: Delete Deployment ───────────────────────────────────────────────
  # Lets the cluster controllers properly terminate pods before removing storage.
  # Same first step as the EKS demo's cleanup_cluster.sh.
  echo ""
  echo "🗑️  Step 1: Deleting Kubernetes Deployment..."
  kubectl delete deployment "${APP_NAME}-deployment" --namespace default --ignore-not-found=true
  echo "   Waiting for pods to terminate..."
  kubectl wait --for=delete pod -l "app=${APP_NAME}" --namespace default --timeout=120s 2>/dev/null || true

  # ── Step 2: Delete PVC ──────────────────────────────────────────────────────
  # Lets the CSI driver properly detach and delete the Azure Managed Disk.
  # If skipped, the disk becomes orphaned (same problem as EKS + EBS).
  echo ""
  echo "🗑️  Step 2: Deleting PersistentVolumeClaim..."
  kubectl delete pvc azure-disk-pv-claim --namespace default --ignore-not-found=true
  echo "   Waiting for PVC deletion..."
  kubectl wait --for=delete pvc/azure-disk-pv-claim --namespace default --timeout=120s 2>/dev/null || true

else
  echo "⚠️  AKS cluster not found or already deleted. Skipping Kubernetes cleanup."
fi

# ── Step 3: Delete Resource Group ────────────────────────────────────────────
# Deletes everything: AKS, VNet, Cosmos DB, Key Vault, Managed Disks, etc.
# Equivalent to terraform destroy in the EKS demo.
echo ""
echo "🗑️  Step 3: Deleting resource group '$RESOURCE_GROUP'..."
echo "   (This may take several minutes)"

if az group show --name "$RESOURCE_GROUP" &>/dev/null; then
  az group delete \
    --name    "$RESOURCE_GROUP" \
    --yes \
    --no-wait
  echo "   Deletion initiated (running in background)."
  echo "   Monitor with: az group show --name $RESOURCE_GROUP --query properties.provisioningState"
else
  echo "   Resource group '$RESOURCE_GROUP' not found – already deleted."
fi

echo ""
echo "✅ Cleanup complete (or already cleaned up)."
echo "   Note: The backend storage account is deleted along with the resource group."
