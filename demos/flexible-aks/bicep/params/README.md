# Bicep Parameter Files

These `.bicepparam` files are Bicep-native parameter files for deploying the AKS cluster **directly** via the Azure CLI, without using `deploy-cluster.sh`.

## When to use these

| Path | Use when |
|------|----------|
| `deploy-cluster.sh` (with `deploy-cluster.params.example`) | Interactive or scripted deployments; handles VNet creation, Entra group setup, and post-deploy configuration automatically |
| These `.bicepparam` files | Direct `az deployment group create` calls; CI/CD pipelines; cases where you manage pre-requisites yourself |

## Usage

1. Choose the file that matches your network topology.
2. Fill in all required placeholder values (see comments in the file).
3. Deploy:

```bash
az deployment group create \
  --resource-group <resource-group> \
  --parameters <config>.bicepparam
```

You can override individual parameters on the command line:

```bash
az deployment group create \
  --resource-group <resource-group> \
  --parameters custom-network.bicepparam \
  --parameters clusterName=my-cluster nodeCount=3
```

## Configurations

### managed-network.bicepparam
Azure-managed VNet. AKS provisions and owns the VNet — no subnet pre-requisite. Public API endpoint. Public Arpio delegate.

### custom-network.bicepparam
Script-created VNet with a public API endpoint. You must provision the VNet and subnet before deploying and supply the subnet resource ID. Public Arpio delegate.

### private-network.bicepparam
Script-created VNet with a **private** API endpoint. You must provision the VNet and subnet before deploying and supply both the subnet and VNet resource IDs (the VNet ID is used to link the Key Vault private DNS zone). Requires a private Arpio delegate.

## Pre-requisites for custom-network and private-network

The VNet and subnet must exist before deployment. `deploy-cluster.sh` creates these automatically; if deploying directly you are responsible for provisioning them.

Minimum subnet requirements:
- `/24` or larger
- No existing delegations that conflict with AKS
- For private-network: the subnet must be reachable from wherever you run `kubectl`
