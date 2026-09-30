#!/usr/bin/env bash
# Deploy the Function App code to Azure.
#
# Usage:
#   bash deploy-function.sh --resource-group <rg> --name <function-app-name>
#
# Bundles Python dependencies into .python_packages/ and deploys via the
# Kudu zipdeploy API. The zip is extracted directly to the filesystem
# (not run-from-package), so the code survives Arpio DR recovery without
# depending on blob storage.
#
# Requires: pip, zip, az CLI, curl
set -euo pipefail

# ---------- Parse arguments ----------
RESOURCE_GROUP=""
FUNCTION_APP_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
        --name)           FUNCTION_APP_NAME="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [[ -z "$RESOURCE_GROUP" || -z "$FUNCTION_APP_NAME" ]]; then
    echo "Usage: bash deploy-function.sh --resource-group <rg> --name <function-app-name>"
    echo ""
    echo "Tip: Get the function app name from the Bicep deployment output:"
    echo "  az deployment group show -g <rg> -n <deployment> --query properties.outputs.functionAppName.value -o tsv"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ---------- Clean up run-from-package if set ----------
# Ensure WEBSITE_RUN_FROM_PACKAGE is not set, so the zip is extracted to
# the filesystem instead of running from blob storage.
echo "Ensuring filesystem-based deployment..."
az functionapp config appsettings delete \
    --resource-group "$RESOURCE_GROUP" \
    --name "$FUNCTION_APP_NAME" \
    --setting-names WEBSITE_RUN_FROM_PACKAGE \
    -o none 2>/dev/null || true

# ---------- Bundle dependencies ----------
echo "Installing Python dependencies for Linux x86_64..."
rm -rf .python_packages
pip install \
    --target .python_packages/lib/site-packages \
    --platform manylinux2014_x86_64 \
    --only-binary=:all: \
    --python-version 3.12 \
    -r requirements.txt \
    --quiet

echo "Dependencies bundled into .python_packages/"

# ---------- Create zip ----------
echo "Creating deployment zip..."
TMPZIP="/tmp/function-app-deploy-$$.zip"
rm -f "$TMPZIP"
trap 'rm -f "$TMPZIP"; rm -rf .python_packages' EXIT

zip -r -q "$TMPZIP" host.json requirements.txt status/ .python_packages/
echo "  Zip size: $(du -h "$TMPZIP" | cut -f1)"

# ---------- Deploy via Kudu zipdeploy API ----------
# Using the Kudu API directly ensures the zip is extracted to wwwroot.
echo "Getting publishing credentials..."
CREDS=$(az functionapp deployment list-publishing-credentials \
    --resource-group "$RESOURCE_GROUP" \
    --name "$FUNCTION_APP_NAME" \
    --query "{user:publishingUserName,pass:publishingPassword}" \
    -o json 2>/dev/null)

KUDU_USER=$(echo "$CREDS" | python3 -c "import sys,json;print(json.load(sys.stdin)['user'])")
KUDU_PASS=$(echo "$CREDS" | python3 -c "import sys,json;print(json.load(sys.stdin)['pass'])")

echo "Deploying to $FUNCTION_APP_NAME via Kudu..."
HTTP_CODE=$(curl -s --max-time 300 \
    -X PUT \
    -u "$KUDU_USER:$KUDU_PASS" \
    --data-binary @"$TMPZIP" \
    -H "Content-Type: application/zip" \
    "https://${FUNCTION_APP_NAME}.scm.azurewebsites.net/api/zip/site/wwwroot/" \
    -o /dev/null -w "%{http_code}")

if [[ "$HTTP_CODE" == "200" ]]; then
    echo ""
    echo "Function App deployed successfully!"
    echo "  URL: https://${FUNCTION_APP_NAME}.azurewebsites.net"
    echo "  Test: curl https://${FUNCTION_APP_NAME}.azurewebsites.net/api/status"
else
    echo ""
    echo "ERROR: Deployment failed with HTTP $HTTP_CODE"
    exit 1
fi
