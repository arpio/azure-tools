# AKS Cluster Deployment

Interactive deployment script for standing up AKS clusters in three network configurations, designed for Arpio demo environments and acceptance testing.

---

## Overview

The script walks through an interactive prompt flow and deploys an AKS cluster using a combination of Azure CLI and Bicep. Three configurations are supported, covering the range from fully Azure-managed networking to fully private, customer-controlled networking.

| Configuration | API Endpoint | VNet | API Server VNet Integration | Arpio Delegate | kubectl from laptop |
|---|---|---|---|---|---|
| `managed-network` | Public | Azure-managed | Yes | Public | Direct |
| `custom-network` | Public | Script-created | No | Public | Direct |
| `private-network` | Private | Script-created | No | Private | `az aks command invoke` |

**Arpio delegate note:** The script does not deploy the Arpio delegate. For `private-network` clusters, a private delegate must be installed inside the cluster VNet after deployment.

---

## Prerequisites

- Bash `>= 4.0` — **macOS ships Bash 3.2 by default.** Install a newer version with `brew install bash` and run the script with it (e.g. `$(brew --prefix bash)/bin/bash ./deploy-cluster.sh`). Windows Git Bash and Linux distros already ship Bash 4+.
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) `>= 2.56.0`
- [Bicep CLI](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install) `>= 0.25.0` (installed via `az bicep install`)
- `openssl` (for suffix hash generation — available natively on Linux and macOS)
- `kubelogin` (for Entra ID auth — converts the kubeconfig to token-based auth; [install instructions](https://azure.github.io/kubelogin/))
- Azure account with permissions to create resource groups, AKS clusters, managed identities, and (if using Entra auth) Entra groups

Verify your setup:

```bash
bash --version
az version
az bicep version
openssl version
```

---

## Usage

### Interactive (no flags required)

```bash
chmod +x deploy-cluster.sh
./deploy-cluster.sh
```

The script walks through all configuration choices interactively.

### With a parameter file

Pre-populate any or all parameters to skip the corresponding prompts:

```bash
cp deploy-cluster.params.example my-cluster.params
# Edit my-cluster.params, then:
./deploy-cluster.sh --params my-cluster.params
```

Any parameter left commented out (or omitted) in the file will still be prompted interactively. Partial files are valid — you can pre-set just the values you always know (e.g. `SUBSCRIPTION_ID`, `LOCATION`, `PREFIX`) and let the rest prompt.

`*.params` files are git-ignored by default to prevent accidental commits of environment-specific settings. See `deploy-cluster.params.example` for the full list of available parameters with descriptions and allowed values.

### Prompt flow

1. **Auth check** — detects current `az` login; prompts browser login if not authenticated
2. **Subscription** — lists subscriptions available to the logged-in user; you pick one
3. **Region** — free text (e.g. `eastus`, `westeurope`, `australiaeast`)
4. **Network configuration** — `managed-network`, `custom-network`, or `private-network`
5. **Networking model** — Azure CNI Overlay or Kubenet (see [Networking](#networking))
   - **Network policy** _(Azure CNI Overlay only)_ — Azure Network Policy or Cilium
6. **Kubernetes auth** — Entra ID or classic certificate auth
   - **Entra admin group** _(Entra only)_ — create a new group and add the current user, or skip and configure access manually
7. **Managed identity** — system-assigned or user-assigned
8. **Resource prefix** — base name for all resources (e.g. `arpio`, `myteam`)
9. **Node pool** — VM SKU and node count (defaults: `Standard_D2s_v3`, 2 nodes)

A summary is shown before any resources are created, with a confirmation prompt.

---

## Resource Naming

All resources are named using a consistent `{prefix}-{resource}-{suffix}` convention.

**Prefix rules:** lowercase letters and numbers only — no hyphens. Minimum 2 characters. This constraint ensures the prefix is directly usable in Azure storage account names, which are the most restrictive common resource type. Examples: `ar`, `arpio`, `myteam`, `staging`.

The suffix is a **deterministic 4-character hash** derived from:
- Your resource prefix
- The selected subscription ID
- Your Azure login username

This means the suffix is stable across repeated runs with the same inputs, making iterative development predictable — re-running the script against the same prefix/subscription/user produces the same resource names every time. Different users or subscriptions using the same prefix will get different suffixes, preventing naming collisions.

The suffix is displayed early in the run so you can note it.

### Resource name map

| Resource | Name |
|---|---|
| Main resource group | `{prefix}-rg-{suffix}` |
| Infra resource group (custom/private only) | `{prefix}-infra-rg-{suffix}` |
| AKS cluster | `{prefix}-aks-{suffix}` |
| VNet (custom/private only) | `{prefix}-vnet-{suffix}` |
| Subnet (custom/private only) | `{prefix}-subnet-{suffix}` |
| Container registry | `{prefix}acr{suffix}` |
| App workload identity | `{prefix}-app-id-{suffix}` |
| User-assigned identity (if selected) | `{prefix}-id-{suffix}` |
| Entra admin group (if Entra auth) | `{prefix}-admins-{suffix}` |

---

## Resource Group Structure

### `managed-network`

One resource group containing all resources:

```
{prefix}-rg-{suffix}
  └── AKS cluster (Azure manages the VNet internally)
  └── Container registry
  └── Key Vault
  └── App workload identity
```

### `custom-network` and `private-network`

Two resource groups, mirroring Azure's own pattern for separating managed infrastructure:

```
{prefix}-rg-{suffix}
  └── AKS cluster
  └── Container registry
  └── Key Vault
  └── App workload identity
  └── Managed identity (if user-assigned)

{prefix}-infra-rg-{suffix}
  └── VNet
  └── Subnet
```

This separation keeps networking independently manageable and makes cleanup explicit.

---

## Networking

### Azure CNI Overlay _(recommended)_

Nodes receive IP addresses from the VNet subnet. Pods receive IPs from a private overlay CIDR (`10.244.0.0/16` by default) that does not consume VNet address space. Invisible to resources outside the cluster.

Best for most workloads. Required for `managed-network` (API server VNet integration depends on CNI). Supports both Azure Network Policy and **Cilium** as the network policy engine — Cilium is prompted as a sub-option when Azure CNI Overlay is selected.

### Kubenet

Nodes receive VNet IPs. Pods receive IPs from a private CIDR routed via Azure-managed UDRs. Simpler but has limitations: no Azure Network Policy support, UDR management overhead, and incompatibility with advanced networking features like API server VNet integration.

Available for `custom-network` and `private-network` only.

### Configuration constraints

| Configuration | Azure CNI Overlay | Kubenet |
|---|---|---|
| `managed-network` | ✅ Required | ❌ Not supported |
| `custom-network` | ✅ | ✅ |
| `private-network` | ✅ | ✅ |

The script enforces this constraint and explains it when prompting for the networking model.

### VNet permissions (custom-network / private-network)

Azure automatically grants the cluster identity network permissions when it
manages the VNet itself (`managed-network`). For `custom-network` and
`private-network`, the VNet is provisioned by this script, so the cluster
identity needs to be granted access explicitly.

The script assigns **Network Contributor** on the VNet to the cluster identity
(system- or user-assigned) after the cluster is created. This lets the
cluster manage the networking resources it needs at runtime — load balancer
frontend IP configurations, private endpoint wiring, and (for Kubenet) route
table entries.

---

## Authentication Options

### Kubernetes auth: Entra ID

Enables Azure Entra ID (`--enable-aad`) with Azure RBAC (`--enable-azure-rbac`). Users authenticate via Entra tokens. Local cluster admin accounts are disabled.

The script automatically:
- Creates an Entra admin group named `{prefix}-admins-{suffix}`
- Adds the currently logged-in user to the group
- Passes the group object ID to the cluster as the admin group

### Kubernetes auth: Classic

Local cluster admin certificate and kubeconfig. No Entra dependency. Useful for isolated test environments or when Entra permissions are not available.

---

## Cluster Identities

### System-assigned

The cluster's managed identity is created automatically by Azure when the cluster is provisioned. Its lifecycle is tied to the cluster — it is deleted when the cluster is deleted.

### User-assigned

The script creates a managed identity (`{prefix}-id-{suffix}`) in the main resource group before cluster creation, then attaches it to the cluster. The currently logged-in user is granted `Managed Identity Operator` on the identity resource.

User-assigned identities persist independently of the cluster and can be reused across deployments.

---

## Workload Identity

The script creates a user-assigned managed identity (`{prefix}-app-id-{suffix}`) intended for use by application pods running in the cluster. The cluster is provisioned with OIDC issuer and Workload Identity enabled, allowing pods to exchange Kubernetes service account tokens for Azure managed identity tokens — no embedded credentials required.

The script outputs everything needed to complete the setup once your app's namespace and service account are known:

| Value | Used for |
|---|---|
| Identity name | database Entra user creation (`CREATE USER`) |
| Client ID | Kubernetes service account annotation |
| Principal ID | Azure role assignments (e.g. PostgreSQL Flexible Server admin) |
| OIDC issuer URL | Federated credential creation |

### Completing the federation

After deployment, run the `az identity federated-credential create` command printed in the completion summary, substituting your app's namespace and service account name.

Then annotate the Kubernetes service account so the webhook can inject the right token:

```bash
kubectl annotate serviceaccount <service-account> \
  --namespace <namespace> \
  azure.workload.identity/client-id=<client-id>
```

And add the label to the pod spec so the Workload Identity webhook injects the token volume:

```yaml
metadata:
  labels:
    azure.workload.identity/use: "true"
```

The identity's principal ID is what you grant access to in PostgreSQL Flexible Server — add it as an Entra administrator or database user using the identity name as the username.

---

## Key Vault

The script deploys a standalone Key Vault with Azure RBAC authorization. The cluster's managed identity is granted **Key Vault Secrets Officer** so workloads can read and write secrets; the deploying user is granted **Key Vault Administrator**. For `private-network` clusters, public access is disabled and a private endpoint is provisioned into the cluster VNet.

### Why not the AKS Key Vault Secrets Provider addon?

The addon mounts Key Vault secrets as files or syncs them into Kubernetes Secrets objects via a CSI driver, and adds automatic rotation polling. It is worth enabling when:

- You have apps that cannot be modified to use the Azure SDK (off-the-shelf software that reads secrets from files or environment variables only).
- You want Kubernetes-native secret rotation without application-side refresh logic.

For this deployment the standalone approach is preferred:

- Apps can use the Azure SDK for authentication via Workload Identity — reading Key Vault secrets the same way is consistent and requires no extra cluster components.
- The addon adds a DaemonSet on every node and requires a `SecretProviderClass` manifest per application, which is extra operational surface for no gain here.
- The standalone Key Vault works identically whether the workload runs in AKS or elsewhere, keeping the app portable.

---

## Container Registry

The script deploys an Azure Container Registry (`{prefix}acr{suffix}`) in the main resource group alongside the cluster.

- **Standard SKU** for `managed-network` and `custom-network`; **Premium SKU** for `private-network` (required for private endpoints)
- Admin credentials are disabled; all authentication is identity-based
- The deploying user is granted **AcrPush** so images can be pushed immediately after deployment
- After cluster creation, the script runs `az aks update --attach-acr` to grant the cluster's kubelet identity **AcrPull** — pods can pull images without embedded credentials

For `private-network` clusters, public network access is disabled and a private endpoint with private DNS zone integration (`privatelink.azurecr.io`) is provisioned into the cluster VNet.

---

## Connecting to a Private Cluster

For `private-network` clusters the Kubernetes API server has no public endpoint. Direct `kubectl` commands from outside the VNet will fail. Use `az aks command invoke` to proxy commands through the Azure control plane — no VPN or network access to the VNet required.

### Running kubectl commands

```bash
az aks command invoke \
  --resource-group <resource-group> \
  --name <cluster-name> \
  --command "kubectl get nodes"
```

### Deploying workloads

Pass manifest files using `--file`. The file is uploaded alongside the command and is available in the working directory when the command runs inside the cluster:

```bash
az aks command invoke \
  --resource-group <resource-group> \
  --name <cluster-name> \
  --command "kubectl apply -f manifest.yaml" \
  --file manifest.yaml
```

Multiple files can be passed with repeated `--file` flags:

```bash
az aks command invoke \
  --resource-group <resource-group> \
  --name <cluster-name> \
  --command "kubectl apply -f deployment.yaml -f service.yaml" \
  --file deployment.yaml \
  --file service.yaml
```

### Limitations

- Log streaming (`kubectl logs -f`), interactive exec (`kubectl exec -it`), and port forwarding (`kubectl port-forward`) are not supported — these require a persistent bidirectional connection to the API server.
- Each invocation has a timeout of approximately 10 minutes.
- Requires `Microsoft.ContainerService/managedClusters/runcommand/action` on the cluster. This is included in the `Azure Kubernetes Service Cluster User` and `Azure Kubernetes Service Cluster Admin` built-in roles.

For interactive access (log streaming, exec, port-forward), connect via VPN or use a jump host deployed inside the cluster VNet.

---

## File Structure

```
flexible-aks/
├── README.md
├── deploy-cluster.sh                  # Cluster deployment script (interactive or --params)
├── deploy-cluster.params.example      # Parameter file template
└── bicep/
    ├── main.bicep            # Orchestrator template
    ├── modules/
    │   ├── cluster.bicep     # AKS cluster (all configs)
    │   ├── network.bicep     # VNet + subnet (custom/private configs)
    │   ├── identity.bicep    # User-assigned managed identity
    │   ├── keyvault.bicep    # Key Vault + RBAC + private endpoint
    │   └── acr.bicep         # Container registry + RBAC + private endpoint
    └── params/
        ├── managed-network.bicepparam
        ├── custom-network.bicepparam
        └── private-network.bicepparam
```

The Bicep modules are parameterized by configuration rather than duplicated per config. `deploy-cluster.sh` handles all interactive logic and passes the correct parameters to Bicep at runtime. The `.bicepparam` files document default values for each configuration and serve as reference.

---

## Cleanup

Delete the resource groups to remove all provisioned resources.

### `managed-network`

```bash
az group delete --name {prefix}-rg-{suffix} --yes
```

### `custom-network` or `private-network`

```bash
az group delete --name {prefix}-rg-{suffix} --yes
az group delete --name {prefix}-infra-rg-{suffix} --yes
```

The container registry is in the main resource group and is deleted along with it.

If you used Entra auth, remove the admin group:

```bash
az ad group delete --group {prefix}-admins-{suffix}
```

---

## Known Limitations

- **Private delegate not provisioned** — for `private-network` clusters, the Arpio private delegate must be installed manually inside the cluster VNet after deployment. The script prints a reminder on completion.
- **`managed-network` requires Azure CNI Overlay** — Kubenet is not supported with API server VNet integration. This is an Azure platform constraint, not a script limitation.
- **VNet address ranges are fixed defaults** — the script uses `10.0.0.0/8` for the VNet and `10.240.0.0/16` for the node subnet. Edit `bicep/modules/network.bicep` to adjust for environments with conflicting CIDR ranges.
- **No app deployment** — `deploy-cluster.sh` provisions infrastructure only. Application deployment (including the workload identity federated credential) is handled separately.
- **Single node pool** — the script provisions a single system node pool. Additional user node pools must be added manually via `az aks nodepool add` after deployment.
