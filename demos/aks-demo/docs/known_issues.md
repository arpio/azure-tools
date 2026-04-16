# Known Issues

## 1. Kubernetes resources fail immediately after AKS cluster creation

### Symptoms

Scripts `03_storage.sh` or `05_application.sh` fail with errors like:

```
Error from server (Forbidden): error when creating "STDIN":
  storageclasses.storage.k8s.io is forbidden: ...
```

or:

```
Unable to connect to the server: dial tcp: i/o timeout
```

### Cause

Although `az deployment group create` for the AKS cluster returns successfully, the
cluster's internal components (CoreDNS, RBAC role bindings, webhook admission controllers)
may not yet be fully ready. The deploy script runs the next step immediately.

This is the Azure equivalent of the EKS demo's known issue #1, where Terraform attempts
to create Kubernetes resources before RBAC propagation is complete.

### Fix

Re-run `ez_cluster_deploy.sh` (or the specific failing script). By the time you retry,
the cluster has had time to finish initializing and the resources will succeed.

For a more robust fix, see [docs/separate_configs.md](./separate_configs.md).

---

## 2. `az deployment group create` fails with "already exists" on re-deploy

### Symptoms

```
(DeploymentNameAlreadyExists) A deployment with the name '01-infrastructure-eastus'
already exists in the resource group.
```

### Cause

Azure ARM deployments are tracked by name within a resource group. The deploy script
uses `--name 01-infrastructure-<env>` which conflicts if the same deployment name was
used in a previous run.

### Fix

The `ez_cluster_deploy.sh` script appends a timestamp to deployment names on retry, or
you can pass `--name` with a unique suffix:

```bash
az deployment group create \
  --resource-group aks-demo-eastus-rg \
  --template-file  bicep/01_infrastructure.bicep \
  --parameters     envName=eastus \
  --name           01-infrastructure-eastus-$(date +%s)
```

---

## 3. Key Vault soft-delete prevents re-deploy with same name

### Symptoms

```
(VaultAlreadyExists) A vault with the same name already exists in deleted state.
You need to either recover or purge existing key vault.
```

### Cause

Azure Key Vault has a soft-delete feature enabled by default. Even after a `az group delete`,
the Key Vault name is reserved for the soft-delete retention period (7 days in this demo,
90 days in production).

### Fix

Purge the deleted Key Vault before re-deploying:

```bash
# List soft-deleted vaults
az keyvault list-deleted --query "[].name" --output tsv

# Purge a specific vault
az keyvault purge --name <vault-name> --location <region>
```

Or use a different `ENV_NAME` to generate a new vault name.

---

## 4. Managed Disk orphaned after forced resource group deletion

### Cause and fix

See [docs/cleanup.md](./cleanup.md). Always use `cleanup_cluster.sh` — never delete the
resource group directly without first running the teardown steps for the Deployment and PVC.
