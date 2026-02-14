#!/usr/bin/env bash
set -euo pipefail

# Build and push the demo-app container image to Azure Container Registry.
# Uses 'az acr build' so no local Docker install is needed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
ACR_NAME="demoacr"
RESOURCE_GROUP="rg-demo-acr"
LOCATION="centralus"
IMAGE_NAME="demo-app"
IMAGE_TAG="latest"

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --acr-name NAME        ACR name (default: demoacr plus suffix for uniqueness)"
    echo "  --resource-group RG    Resource group (default: rg-demo-acr)"
    echo "  --location LOC         Azure region (default: centralus)"
    echo "  -h, --help             Show this help"
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --acr-name) ACR_NAME="$2"; shift 2 ;;
        --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
        --location) LOCATION="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Append deterministic suffix for global uniqueness (ACR names must be globally unique)
SUFFIX=$(printf '%s' "$RESOURCE_GROUP" | shasum | head -c 5)
ACR_NAME="${ACR_NAME}${SUFFIX}"

echo ""
echo "=== Build Configuration ==="
echo "  ACR Name:        $ACR_NAME"
echo "  Resource Group:  $RESOURCE_GROUP"
echo "  Location:        $LOCATION"
echo "  Image:           $IMAGE_NAME:$IMAGE_TAG"
echo "  Build Context:   $SCRIPT_DIR"
echo ""
read -r -p "Proceed? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

# Create resource group if needed
echo ""
echo "--- Ensuring resource group '$RESOURCE_GROUP' exists ---"
az group create -n "$RESOURCE_GROUP" -l "$LOCATION" -o none

# Create ACR if it doesn't exist
echo ""
echo "--- Ensuring ACR '$ACR_NAME' exists ---"
if ! az acr show -n "$ACR_NAME" -g "$RESOURCE_GROUP" &>/dev/null; then
    echo "Creating ACR '$ACR_NAME' (Basic SKU)..."
    az acr create -n "$ACR_NAME" -g "$RESOURCE_GROUP" -l "$LOCATION" --sku Basic --admin-enabled false -o none
else
    echo "ACR '$ACR_NAME' already exists."
fi

# Build and push using az acr build (no local Docker needed)
echo ""
echo "--- Building and pushing image ---"
az acr build \
    --registry "$ACR_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --image "${IMAGE_NAME}:${IMAGE_TAG}" \
    "$SCRIPT_DIR"

# Get the full image URI
LOGIN_SERVER=$(az acr show -n "$ACR_NAME" -g "$RESOURCE_GROUP" --query loginServer -o tsv)
FULL_IMAGE="${LOGIN_SERVER}/${IMAGE_NAME}:${IMAGE_TAG}"

echo ""
echo "=== Build Complete ==="
echo "  Image URI:  $FULL_IMAGE"
echo "  ACR Name:   $ACR_NAME"
echo ""
echo "Use these values in your Bicep deployment:"
echo "  param acrName = '$ACR_NAME'"
echo "  param containerImage = '$FULL_IMAGE'"
