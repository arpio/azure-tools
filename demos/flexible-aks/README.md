# AKS Cluster Deployment

Interactive deployment script for standing up AKS clusters in three network configurations, designed for Arpio demo environments and acceptance testing.

---

## Overview

The script walks through an interactive prompt flow and deploys an AKS cluster using a combination of Azure CLI and Bicep. Three configurations are supported, covering the range from fully Azure-managed networking to fully private, customer-controlled networking.

| Configuration | API Endpoint | VNet | API Server VNet Integration | Arpio Delegate |
|---|---|---|---|---|
| `managed-network` | Public | Azure-managed | Yes | Public |
| `custom-network` | Public | Script-created | No | Public |
| `private-network` | Private | Script-created | No | Private |

**Arpio delegate note:** The script does not deploy the Arpio delegate. For `private-network` clusters, a private delegate must be installed inside the cluster VNet after deployment.

---

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli) `>= 2.56.0`
- [Bicep CLI](https://learn.microsoft.com/en-us/azure/azure-resource-manager/bicep/install) `>= 0.25.0` (installed via `az bicep install`)
- `openssl` (for suffix hash generation — available natively on Linux and macOS)
- Azure account with permissions to create resource groups, AKS clusters, managed identities, and (if using Entra auth) Entra groups

Verify your setup:

```bash
az version
az bicep version
openssl version
```

---

## Usage

```bash
chmod +x deploy-cluster.sh
./deploy-cluster.sh
```

The script is fully interactive — no flags required. Follow the prompts in order.

### Prompt flow

1. **Auth check** — detects current `az` login; prompts browser login if not authenticated
2. **Subscription** — lists subscriptions available to the logged-in user; you pick one
3. **Region** — free text (e.g. `eastus`, `westeurope`, `australiaeast`)
4. **Network configuration** — `managed-network`, `custom-network`, or `private-network`
5. **Networking model** — Azure CNI Overlay or Kubenet (see [Networking](#networking))
6. **Kubernetes auth** — Entra ID or classic certificate auth
7. **Managed identity** — system-assigned or user-assigned
8. **Resource prefix** — base name for all resources (e.g. `arpio`, `myteam`)
9. **Node pool** — VM SKU and node count (defaults: `Standard_D2s_v3`, 2 nodes)

A summary is shown before any resources are created, with a confirmation prompt.

---

## Resource Naming

All resources are named using a consistent `{prefix}-{resource}-{suffix}` convention.

**Prefix rules:** lowercase alphanumeric, hyphens allowed in the middle, minimum 2 characters, no leading or trailing hyphens. Examples: `ar`, `arpio`, `myteam-aks`.

The suffix is a **deterministic 6-character hash** derived from:
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
| User-assigned identity (if selected) | `{prefix}-id-{suffix}` |
| Entra admin group (if Entra auth) | `{prefix}-admins-{suffix}` |

---

## Resource Group Structure

### `managed-network`

One resource group containing all resources:

```
{prefix}-rg-{suffix}
  └── AKS cluster (Azure manages the VNet internally)
```

### `custom-network` and `private-network`

Two resource groups, mirroring Azure's own pattern for separating managed infrastructure:

```
{prefix}-rg-{suffix}
  └── AKS cluster
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

Best for most workloads. Required for `managed-network` (API server VNet integration depends on CNI).

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

## Managed Identity

### System-assigned

The cluster's managed identity is created automatically by Azure when the cluster is provisioned. Its lifecycle is tied to the cluster — it is deleted when the cluster is deleted.

### User-assigned

The script creates a managed identity (`{prefix}-id-{suffix}`) in the main resource group before cluster creation, then attaches it to the cluster. The currently logged-in user is granted `Managed Identity Operator` on the identity resource.

User-assigned identities persist independently of the cluster and can be reused across deployments.

---

## File Structure

```
flexible-aks/
├── README.md
├── deploy-cluster.sh         # Interactive deployment script
└── bicep/
    ├── main.bicep            # Orchestrator template
    ├── modules/
    │   ├── cluster.bicep     # AKS cluster (all configs)
    │   ├── network.bicep     # VNet + subnet (custom/private configs)
    │   └── identity.bicep    # User-assigned managed identity
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

If you used Entra auth, remove the admin group:

```bash
az ad group delete --group {prefix}-admins-{suffix}
```

---

## Known Limitations

- **Private delegate not provisioned** — for `private-network` clusters, the Arpio private delegate must be installed manually inside the cluster VNet after deployment. The script prints a reminder on completion.
- **`managed-network` requires Azure CNI Overlay** — Kubenet is not supported with API server VNet integration. This is an Azure platform constraint, not a script limitation.
- **VNet address ranges are fixed defaults** — the script uses `10.0.0.0/8` for the VNet and `10.240.0.0/16` for the node subnet. Edit `bicep/modules/network.bicep` to adjust for environments with conflicting CIDR ranges.
- **No app deployment** — demo app and datasource deployment is handled by a separate script (`deploy-app.sh`, not yet implemented).
- **Single node pool** — the script provisions a single system node pool. Additional user node pools must be added manually via `az aks nodepool add` after deployment.
