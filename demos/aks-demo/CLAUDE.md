# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an educational project that deploys a demo "guestbook" application on Azure Kubernetes Service (AKS). It is the Azure equivalent of [setheliot/eks_demo](https://github.com/setheliot/eks_demo) and demonstrates AKS best practices including VNet setup, managed node pools, nginx Ingress Controller, Azure Disk CSI storage, Cosmos DB integration, and Azure Key Vault with the Secrets Store CSI driver.

IaC is **Bicep + Azure CLI** (not Terraform). Kubernetes resources are applied via **kubectl** in bash scripts.

## Commands

### Deploy the cluster
```bash
cd scripts
./ez_cluster_deploy.sh
```
This interactive script validates Azure login, checks backend storage, and deploys all resources.

### Tear down the cluster
```bash
cd scripts
./cleanup_cluster.sh -env-file=../bicep/environment/eastus.env
```

### Manual step-by-step deployment (from repo root)
```bash
# Set subscription
az account set --subscription <subscription-id>

# Create resource group
az group create --name aks-demo-<env>-rg --location <region>

# 01 – Infrastructure
az deployment group create \
  --resource-group aks-demo-<env>-rg \
  --template-file  bicep/01_infrastructure.bicep \
  --parameters     envName=<env> location=<region>

# 02 – Ingress controller
bash scripts/02_ingress_controller.sh aks-demo-<env>-rg aks-demo-<env>-cluster

# 03 – Storage
bash scripts/03_storage.sh aks-demo-<env>-rg aks-demo-<env>-cluster

# 04 – Workload Identity
az deployment group create \
  --resource-group aks-demo-<env>-rg \
  --template-file  bicep/04_authentication.bicep \
  --parameters     prefixEnv=aks-demo-<env> oidcIssuerUrl=<url> \
                   cosmosAccountId=<id> cosmosAccountName=<name>

# 06 – Key Vault
az deployment group create \
  --resource-group aks-demo-<env>-rg \
  --template-file  bicep/06_key_vault.bicep \
  --parameters     prefixEnv=aks-demo-<env> deployerObjectId=<oid> \
                   appIdentityPrincipalId=<pid> aksClusterId=<id>

# 05 – Application
bash scripts/05_application.sh aks-demo-<env>-rg aks-demo-<env>-cluster \
  <client-id> <cosmos-endpoint> guestbook guests <region> \
  <kv-name> <tenant-id> <secret-name>
```

## Architecture

### File structure
```
bicep/
  01_infrastructure.bicep    # VNet, NAT GW, AKS cluster (system + user pools), Cosmos DB
  03_storage_docs.bicep      # Documentation of StorageClass/PVC YAML (applied by script)
  04_authentication.bicep    # Workload Identity: Managed Identity + Federated Credential
  06_key_vault.bicep         # Key Vault + Key Vault CSI add-on + secret
  environment/               # Per-environment .env files (equivalent to .tfvars)

scripts/
  ez_cluster_deploy.sh       # Main orchestration script
  cleanup_cluster.sh         # Teardown script
  02_ingress_controller.sh   # Installs nginx Ingress Controller via Helm
  03_storage.sh              # Applies StorageClass + PVC via kubectl
  05_application.sh          # Applies K8s ServiceAccount, Deployment, Service, Ingress

docs/
  cleanup.md                 # Explains why teardown order matters (disk orphan problem)
  known_issues.md            # Known issues and workarounds
  separate_configs.md        # Discussion of single vs. separate deploy configs
```

### Numbered file convention
Files are numbered to indicate logical deployment order (same convention as the EKS demo):
- `01` – Azure infrastructure (ARM resources: VNet, AKS, Cosmos DB)
- `02` – Ingress controller (Helm)
- `03` – Persistent storage (kubectl)
- `04` – Pod identity (ARM: Managed Identity + Federated Credential)
- `05` – Application (kubectl: Deployment, Service, Ingress)
- `06` – Secrets (ARM: Key Vault + CSI add-on)
- `07` – Reserved (see `scripts/07_reserved.md`)

### Key patterns

**Environment files** — `bicep/environment/*.env` files are sourced by the deploy script.
The `ENV_NAME` variable must be unique per environment and is used in all resource names:
`aks-demo-<ENV_NAME>-<resource-type>`

**Resource naming** — Uses `aks-demo-<env_name>` prefix pattern, stored as `prefixEnv` in
Bicep parameters. Equivalent to `local.prefix_env` in the EKS demo.

**Azure Workload Identity** — Equivalent to EKS IRSA. Pods annotated with
`azure.workload.identity/client-id: <managed-identity-client-id>` automatically receive
Azure credentials. The federated credential restricts access to a specific
`system:serviceaccount:<namespace>:<name>` — same mechanism as IRSA's StringEquals conditions.

**Storage pattern (Azure Disk CSI)**
- Built into AKS — no installation needed (unlike EKS where `aws-ebs-csi-driver` is an add-on)
- StorageClass uses `WaitForFirstConsumer` — disk created in the same AZ as the scheduled pod
- PVC uses `ReadWriteOnce` — Azure Managed Disks attach to one node at a time (same as EBS)
- App mounts the PVC at `/app/data`

**Secrets pattern (Key Vault CSI)**
- Two components: Secrets Store CSI Driver + Azure Key Vault Provider
- Deployed as a managed AKS extension (no manual DaemonSet needed, unlike EKS demo)
- `SecretProviderClass` (applied in `05_application.sh`) maps Key Vault secrets to pod volumes
- Secrets appear as files at `/mnt/secrets` inside containers

**Cluster autoscaler**
- AKS native: `enableAutoScaling: true` on node pool definitions in `01_infrastructure.bicep`
- No Helm chart or IAM policy needed (unlike the EKS demo's `08_cluster_autoscaler.tf`)
- Tuning via `autoScalerProfile` block in the cluster resource

**Teardown order**
Always use `cleanup_cluster.sh`. Running `az group delete` directly without first deleting
the Deployment and PVC will leave an orphaned Azure Managed Disk. See `docs/cleanup.md`.

## AWS → Azure quick reference

| AWS (EKS demo) | Azure (this repo) |
|---|---|
| `terraform apply` | `az deployment group create` |
| S3 + DynamoDB state backend | Azure Blob Storage |
| VPC module | `Microsoft.Network/virtualNetworks` |
| EKS module | `Microsoft.ContainerService/managedClusters` |
| IRSA annotation | `azure.workload.identity/client-id` annotation |
| `ebs.csi.aws.com` StorageClass | `disk.csi.azure.com` StorageClass |
| AWS LBC + ALB | nginx Ingress Controller + Azure Load Balancer |
| DynamoDB | Cosmos DB (NoSQL API) |
| Secrets Manager | Azure Key Vault |
| Cluster Autoscaler Helm chart | AKS `enableAutoScaling: true` |
