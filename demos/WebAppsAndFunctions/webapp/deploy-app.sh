#!/usr/bin/env bash
# Deploy the Web App code to Azure.
#
# Usage:
#   bash deploy-app.sh --resource-group <rg> --name <webapp-name>
#
# Bundles Python dependencies and deploys via the Kudu zipdeploy API.
# The zip is extracted directly to the filesystem (no server-side build),
# so the code survives Arpio DR recovery without depending on Oryx/SCM builds.
#
# Requires: pip, zip, az CLI, curl
set -euo pipefail

# ---------- Parse arguments ----------
RESOURCE_GROUP=""
WEBAPP_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --resource-group) RESOURCE_GROUP="$2"; shift 2 ;;
        --name)           WEBAPP_NAME="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [[ -z "$RESOURCE_GROUP" || -z "$WEBAPP_NAME" ]]; then
    echo "Usage: bash deploy-app.sh --resource-group <rg> --name <webapp-name>"
    echo ""
    echo "Tip: Get the web app name from the Bicep deployment output:"
    echo "  az deployment group show -g <rg> -n <deployment> --query properties.outputs.webAppName.value -o tsv"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ---------- Bundle dependencies ----------
# Install packages targeting Linux x86_64 (Azure App Service platform).
# This makes the zip self-contained so it works after Arpio DR recovery
# without needing a server-side pip install / Oryx build.

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
TMPZIP="/tmp/webapp-deploy-$$.zip"
rm -f "$TMPZIP"
trap 'rm -f "$TMPZIP"; rm -rf .python_packages' EXIT

zip -r -q "$TMPZIP" app.py requirements.txt .python_packages/
echo "  Zip size: $(du -h "$TMPZIP" | cut -f1)"

# ---------- Deploy via Kudu zipdeploy API ----------
echo "Getting publishing credentials..."
CREDS=$(az webapp deployment list-publishing-credentials \
    --resource-group "$RESOURCE_GROUP" \
    --name "$WEBAPP_NAME" \
    --query "{user:publishingUserName,pass:publishingPassword}" \
    -o json 2>/dev/null)

KUDU_USER=$(echo "$CREDS" | python3 -c "import sys,json;print(json.load(sys.stdin)['user'])")
KUDU_PASS=$(echo "$CREDS" | python3 -c "import sys,json;print(json.load(sys.stdin)['pass'])")

echo "Deploying to $WEBAPP_NAME via Kudu..."
HTTP_CODE=$(curl -s --max-time 300 \
    -X PUT \
    -u "$KUDU_USER:$KUDU_PASS" \
    --data-binary @"$TMPZIP" \
    -H "Content-Type: application/zip" \
    "https://${WEBAPP_NAME}.scm.azurewebsites.net/api/zip/site/wwwroot/" \
    -o /dev/null -w "%{http_code}")

if [[ "$HTTP_CODE" == "200" ]]; then
    echo ""
    echo "Web App deployed successfully!"
    echo "  URL: https://${WEBAPP_NAME}.azurewebsites.net"
    echo ""
    echo "Note: First request may take a few seconds while the app starts."
else
    echo ""
    echo "ERROR: Deployment failed with HTTP $HTTP_CODE"
    exit 1
fi
