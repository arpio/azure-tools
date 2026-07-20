# Azure AKS Demo

This repo deploys a complete demo app on Azure Kubernetes Service (AKS), using **Azure CLI**, **Bicep**, and **bash**. It is the Azure equivalent of [setheliot/eks_demo](https://github.com/setheliot/eks_demo) and mirrors its structure, numbered file convention, and educational inline comments.

## Deployed resources

| Resource | Azure | AWS (EKS demo equivalent) |
|---|---|---|
| Network | Virtual Network, node subnet, public subnet, NAT Gateway | VPC, private/public subnets, NAT Gateway |
| Cluster | AKS (system + user node pools) | EKS + managed node group |
| Autoscaler | AKS built-in cluster autoscaler | Cluster Autoscaler Helm chart |
| Load balancer | nginx Ingress Controller + Azure Standard LB | AWS Load Balancer Controller + ALB |
| Persistent storage | Azure Disk CSI → Managed Disk (Premium_LRS) | EBS CSI → EBS gp3 volume |
| Database | Cosmos DB (NoSQL API) | DynamoDB |
| Pod identity | Azure Workload Identity | EKS IRSA |
| Secrets | Azure Key Vault + Secrets Store CSI add-on | AWS Secrets Manager + Secrets Store CSI |
| Terraform/state backend | Azure Blob Storage | S3 + DynamoDB |

## Prerequisites

- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli) (`az`)
- [Helm](https://helm.sh/docs/intro/install/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- Bicep (bundled with Azure CLI ≥ 2.20 — the script runs `az bicep install` automatically)

## Deploy

### Option 1 — Automatic (recommended)

1. Update `SUBSCRIPTION_ID` in `bicep/environment/eastus.env` (or create a new `.env` file).
2. Run:

```bash
cd scripts
./ez_cluster_deploy.sh
```

The script will:
- Verify Azure login and show you the target subscription
- Let you choose an environment file
- Create backend storage automatically
- Deploy all infrastructure via Bicep
- Install the nginx Ingress Controller via Helm
- Apply StorageClass, PVC, Workload Identity, Key Vault, and app manifests
- Print the app URL when ready

### Option 2 — Step by step

```bash
# Set your subscription
az account set --subscription <your-subscription-id>

# Create resource group
az group create --name aks-demo-eastus-rg --location eastus

# 01 – Infrastructure
az deployment group create \
  --resource-group aks-demo-eastus-rg \
  --template-file  bicep/01_infrastructure.bicep \
  --parameters     envName=eastus location=eastus

# 02 – Ingress controller
bash scripts/02_ingress_controller.sh aks-demo-eastus-rg aks-demo-eastus-cluster

# 03 – Storage
bash scripts/03_storage.sh aks-demo-eastus-rg aks-demo-eastus-cluster

# 04 – Workload Identity
az deployment group create \
  --resource-group aks-demo-eastus-rg \
  --template-file  bicep/04_authentication.bicep \
  --parameters     prefixEnv=aks-demo-eastus oidcIssuerUrl=<from-step-01> \
                   cosmosAccountId=<id> cosmosAccountName=<name>

# 06 – Key Vault
az deployment group create \
  --resource-group aks-demo-eastus-rg \
  --template-file  bicep/06_key_vault.bicep \
  --parameters     prefixEnv=aks-demo-eastus deployerObjectId=<your-object-id> \
                   appIdentityPrincipalId=<from-step-04> aksClusterId=<id>

# 05 – Application
bash scripts/05_application.sh aks-demo-eastus-rg aks-demo-eastus-cluster \
  <app-identity-client-id> <cosmos-endpoint> guestbook guests eastus \
  <kv-name> <tenant-id> <secret-name>
```

Use `http://<ingress-ip>` (not https). It may take ~1 minute after deployment for the application to be available.

## Tear down

```bash
cd scripts
./cleanup_cluster.sh -env-file=../bicep/environment/eastus.env
```

The cleanup script follows the same destruction order as the EKS demo:
1. **Delete the Deployment** — lets cluster controllers terminate pods cleanly
2. **Delete the PVC** — lets the CSI driver detach and delete the Managed Disk
3. **Delete the Resource Group** — removes everything else

> Without step 2, the Azure Managed Disk becomes orphaned (same problem as EBS on EKS described in [cleanup.md](docs/cleanup.md)).

## File structure

```
aks_demo/
├── bicep/
│   ├── 01_infrastructure.bicep    # VNet, AKS cluster, Cosmos DB
│   ├── 03_storage_docs.bicep      # Storage documentation (K8s resources applied by script)
│   ├── 04_authentication.bicep    # Workload Identity (Managed Identity + Federated Credential)
│   ├── 06_key_vault.bicep         # Key Vault + CSI add-on
│   └── environment/
│       ├── eastus.env             # Equivalent to eastus.tfvars
│       └── westus2.env
├── scripts/
│   ├── ez_cluster_deploy.sh       # Main deploy script (run this)
│   ├── cleanup_cluster.sh         # Tear-down script
│   ├── 02_ingress_controller.sh   # nginx Ingress Controller (Helm)
│   ├── 03_storage.sh              # StorageClass + PVC
│   └── 05_application.sh          # K8s ServiceAccount, Deployment, Service, Ingress
└── docs/
    └── cleanup.md                 # Why the teardown order matters
```

## AWS → Azure mapping

| Concept | AWS (EKS demo) | Azure (this repo) |
|---|---|---|
| IaC | Terraform | Bicep + Azure CLI |
| State backend | S3 + DynamoDB lock | Azure Blob Storage |
| Network | `terraform-aws-modules/vpc` | `Microsoft.Network/virtualNetworks` |
| Cluster | `terraform-aws-modules/eks` | `Microsoft.ContainerService/managedClusters` |
| Pod identity | IRSA (`eks.amazonaws.com/role-arn`) | Workload Identity (`azure.workload.identity/client-id`) |
| Storage CSI | `ebs.csi.aws.com` (add-on) | `disk.csi.azure.com` (built-in) |
| Ingress | AWS LBC + ALB | nginx + Azure Load Balancer |
| Database | DynamoDB | Cosmos DB (NoSQL API) |
| Secrets | AWS Secrets Manager | Azure Key Vault |
| Autoscaler | Helm chart + ASG tags | AKS native (`enableAutoScaling: true`) |

---

Feedback and pull requests welcome. [MIT License](LICENSE)
