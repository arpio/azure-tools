# Single deploy script or separate ones?

## The approach taken here

`ez_cluster_deploy.sh` deploys everything in a single run: Azure infrastructure (Bicep),
the nginx Ingress Controller (Helm), storage and app manifests (kubectl). This mirrors the
EKS demo's single-Terraform-config approach.

**Why single-script for this demo:**
- Simpler to understand — one command, one flow
- Right for an educational repo focused on showing how the pieces fit together
- Equivalent to the EKS demo's `terraform apply` deploying everything at once

## The challenge with single-script deploys

Deploying Kubernetes resources immediately after AKS cluster creation can fail because:

1. `az deployment group create` returns as soon as the AKS control plane is provisioned
2. But the node pools, CoreDNS pods, RBAC role bindings, and webhook admission controllers
   are still initializing in the background
3. `kubectl apply` in the next script runs before the cluster is fully ready

This produces transient errors like:
```
storageclasses.storage.k8s.io is forbidden: ... cannot create resource
```

Re-running the script succeeds because by then the cluster has finished initializing.

This is identical to the EKS demo's single-config challenge, where `depends_on = [module.eks]`
and `dataplane_wait_duration = "60s"` are used as workarounds.

## A better approach for production: two separate deploys

Split the work into two independent scripts:

**Script 1 — Infrastructure** (`deploy_infra.sh`):
Runs Bicep for all Azure ARM resources: VNet, AKS cluster, Cosmos DB, Managed Identity,
Key Vault. Exits after the cluster is confirmed healthy.

```bash
# Wait for all node pools to be ready before exiting
az aks wait \
  --resource-group "$RESOURCE_GROUP" \
  --name           "$CLUSTER_NAME" \
  --updated \
  --interval       10 \
  --timeout        600
```

**Script 2 — Kubernetes** (`deploy_k8s.sh`):
Runs after Script 1 has completed and the cluster is confirmed ready. Installs the nginx
controller, applies StorageClass/PVC, deploys the application.

### Benefits of separation

- Script 1 can be run by an infrastructure team; Script 2 by an app team
- On `destroy`, Script 2 (Kubernetes teardown) can run first while the cluster is still
  healthy, then Script 1 (ARM teardown) removes the infrastructure cleanly
- No timing-dependent retry loops needed
- Mirrors best practices for production AKS deployments

### Why this repo keeps the single-script approach

The focus here is education and simplicity: showing how EKS and AKS concepts map to each
other. A single `./ez_cluster_deploy.sh` is the right user experience for that goal.

For production, separate your infrastructure and Kubernetes configurations.
