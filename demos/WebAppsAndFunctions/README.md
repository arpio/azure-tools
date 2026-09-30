# Web Apps, Functions & Container Apps Demo (Arpio Demo 05)

Azure Web App + Function App + Container App + Key Vault demo for Arpio disaster recovery.
Showcases Arpio protection across the three main Azure compute models for apps:
App Service, Functions, and Container Apps.

## Architecture

```
Internet
   |
   v
Web App (Flask, Python 3.12, Basic B1)  ── dashboard
   |
   +---> Function App /api/status (Python 3.12, Basic B1, v1 model)
   |         |
   |         +---> Key Vault (read secrets)
   |
   +---> Container App config (read live via Azure Resource Manager API)
   |
   +---> Key Vault (demo-secret, app-region, storage-blob-url)
   |
   +---> Blob Storage (Arpio logo from assets container)

Container App (background worker, busybox heartbeat, no HTTP ingress)
   +---> Container Apps Environment ──> Log Analytics workspace
```

**Resources deployed:**
- App Service Plan (Basic B1, Linux) + Web App
- App Service Plan (Basic B1, Linux) + Function App
- Container Apps Environment + Container App (background worker, public busybox image)
- Log Analytics workspace (Container App logs)
- Key Vault (RBAC-enabled, 3 secrets)
- Storage Account (public blob, Arpio logo) + Storage Account (Function App backing store)
- User-Assigned Managed Identity (shared by Web App, Function App, and Container App)
- Deployment Scripts (push code to Kudu + upload logo)
- All tagged with `ArpioDemo05: True`

The Container App is a **background worker** (no HTTP endpoint) running a public sample
image (`mcr.microsoft.com/cbl-mariner/busybox:2.0`). Its configuration (environment
variables, image, revision) is read live from the Azure Resource Manager API by the
Web App dashboard using the shared managed identity. After Arpio recovery, the dashboard
shows the recovered worker's translated configuration.

## Prerequisites

- Azure CLI (`az`) logged in with an active subscription
- Azure Functions Core Tools v4 (`func`) — install via `npm install -g azure-functions-core-tools@4` (only needed for standalone code updates)

## Deployment (Single Command)

Everything — infrastructure, app code, dependencies, and logo — is deployed in a single command:

```bash
# Set your subscription
az account set --subscription <subscription_id>

# Create resource group
az group create -n wad05-rg -l eastus2

# Deploy everything
az deployment group create \
  --name wad05-deploy \
  --resource-group wad05-rg \
  --template-file azuredeploy.bicep \
  --parameters azuredeploy.bicepparam
```

The Bicep template uses `loadTextContent()` to embed the app code and `deploymentScripts` resources to install Python dependencies and push the bundled zip to each app's filesystem via Kudu. No separate deploy step needed.

### Get the dashboard URL

```bash
az deployment group show -g wad05-rg -n wad05-deploy \
  --query properties.outputs.webAppUrl.value -o tsv
```

## How It Works

1. **Bicep** creates all Azure resources (App Service, Function App, Key Vault, Storage)
2. **Deployment scripts** (running in Azure Container Instances) bundle Python dependencies and push code to each app via Kudu `/api/zip/site/wwwroot/`
3. **Web App** serves a Flask dashboard showing all resource statuses
4. **Web App** calls the Function App's `/api/status` HTTP endpoint
5. **Web App** reads the Container App worker's config from the Azure Resource Manager API
6. **All apps** use a shared user-assigned managed identity (Key Vault access + ARM read)

## Standalone Code Updates (Optional)

If you only need to update app code without redeploying infrastructure, you can use the deploy scripts directly:

```bash
# Web App
cd webapp
bash deploy-app.sh --resource-group wad05-rg --name <webapp-name>

# Function App
cd function-app
bash deploy-function.sh --resource-group wad05-rg --name <function-app-name>
```

Or simply re-run the Bicep deployment — the `forceUpdateTag` (code hash) will trigger redeployment only when code files change.

## Local Testing

Test the Web App dashboard locally (without Azure services):

```bash
cd webapp
bash run-local.sh
# Open http://localhost:8080
```

## Cleanup

```bash
az group delete -n wad05-rg --yes --no-wait
```

## Arpio DR Notes

After Arpio recovery:
- Web App and Function App are restored with their app settings and code on the filesystem
- The managed identity and Key Vault RBAC role assignments are recovered
- The Function App URL in the Web App's settings points to the recovered Function App
- Key Vault secrets (`demo-secret`, `app-region`, `storage-blob-url`) are preserved
- `storage-blob-url` is translated to the recovered blob storage account
- `app-region` uses ARM location resource ID format for Arpio translation
- The Arpio logo in blob storage is replicated via Change Feed
- The Container App (background worker) and its Container Apps Environment are recovered;
  the dashboard reads the recovered worker's translated configuration via the ARM API
