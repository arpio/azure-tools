# App Gateway + Container Instances Demo

Deploys an **Application Gateway → Azure Container Instances** stack with **Key Vault**, **Blob Storage**, and **Queue Storage** accessed via private endpoints. Demonstrates a different set of Azure resources that Arpio protects compared to the Load Balancer + VM demo.

## Architecture

![architecture](./images/appgw-container-architecture.jpg)

```
Internet → Application Gateway (public IP)
               ↓ HTTP :80
           ACI Group 1 (:8000)  ←──→  Key Vault (private endpoint)
           ACI Group 2 (:8000)  ←──→  Blob Storage (private endpoint)
                                ←──→  Queue Storage (private endpoint)
```

**Networking (VNet `10.1.0.0/16`):**

| Subnet | CIDR | Purpose |
|--------|------|---------|
| `subnet-appgw` | `10.1.0.0/24` | Application Gateway |
| `subnet-aci` | `10.1.1.0/24` | Container Instances (delegated) |
| `subnet-pe` | `10.1.2.0/24` | Private Endpoints |

**Private Endpoints:**
- Storage Blob (`privatelink.blob.core.windows.net`)
- Storage Queue (`privatelink.queue.core.windows.net`)
- Key Vault (`privatelink.vaultcore.azure.net`)

## Prerequisites

- Azure CLI (`az`) installed and logged in
- A resource group for the ACR (created by `build_image.sh`, reusable across demos)
- A resource group for the infrastructure

## Deploy

### Step 1: Build the container image

```bash
cd demos/demo-app
bash build_image.sh
```

This creates an Azure Container Registry and builds/pushes the image. Note the output values for `acrName` and `containerImage`.

If you get this error: `MissingSubscriptionRegistration`, then you need to first execute the following command and let it complete (it can take a few minutes)
```bash
az provider register --namespace Microsoft.ContainerRegistry
```

### Step 2: Update parameters

Edit `azuredeploy.bicepparam` with the ACR name and image URI from step 1:

```
param acrName = 'demoacrXXXXX'
param acrResourceGroup = 'rg-demo-acr'
param containerImage = 'demoacrXXXXX.azurecr.io/demo-app:latest'
```

### Step 3: Deploy infrastructure

```bash
cd ../appgw-container-iac

az group create -n rg-appgw-aci -l centralus

az deployment group create \
  --name appgw-aci-deploy \
  --resource-group rg-appgw-aci \
  --template-file azuredeploy.bicep \
  --parameters azuredeploy.bicepparam
```

### Step 4: Access the app

The deployment outputs the Application Gateway FQDN. Open it in a browser:

```bash
az deployment group show \
  --resource-group rg-appgw-aci \
  --name appgw-aci-deploy \
  --query properties.outputs.appGatewayFQDN.value -o tsv
```

## Demo Features

- **Dashboard** (`/`): Shows hostname and connectivity status for Key Vault, Blob Storage, and Queue Storage
- **Secrets** (`/secrets`): Create, view, and delete Key Vault secrets
- **Blobs** (`/blobs`): Upload text blobs, download, and delete
- **Queues** (`/queues`): Send messages, receive/dequeue, peek at queue contents
- **Load balancing**: Refresh the page to see the hostname alternate between container instances

## Cleanup

```bash
az group delete -n rg-appgw-aci --yes --no-wait
az group delete -n rg-demo-acr --yes --no-wait  # if no longer needed
```
