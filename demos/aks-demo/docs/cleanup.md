# Tear-down (clean up) all resources — explained

## Why the teardown order matters

We enforce this specific destruction order:

1. **Delete the Kubernetes Deployment** → pods terminate cleanly
2. **Delete the PersistentVolumeClaim (PVC)** → Azure Disk CSI detaches + deletes Managed Disk
3. **Delete the Resource Group** → removes everything else

This mirrors the same rationale in [setheliot/eks_demo](https://github.com/setheliot/eks_demo).

### What goes wrong without this order?

If you delete the Resource Group (or AKS cluster) first:

- The AKS cluster is gone, so the Azure Disk CSI driver never runs its teardown logic
- The PVC `azure-disk-pv-claim` can't be reconciled because there's no cluster
- The Managed Disk backing the PV **is NOT automatically deleted**
- You end up with an orphaned Premium SSD disk in your subscription, accruing charges

This is the Azure equivalent of the EKS demo's EBS orphan problem when `terraform destroy` is run without targeting resources in order.

### The correct sequence

```bash
# 1. Delete Deployment (pods must be gone before PVC can be deleted)
kubectl delete deployment <app>-deployment

# 2. Wait for pods to terminate
kubectl wait --for=delete pod -l app=<app> --timeout=120s

# 3. Delete PVC (CSI driver detaches + deletes the Managed Disk)
kubectl delete pvc azure-disk-pv-claim

# 4. Wait for PVC deletion
kubectl wait --for=delete pvc/azure-disk-pv-claim --timeout=120s

# 5. Now safe to delete the resource group
az group delete --name <rg> --yes
```

The `cleanup_cluster.sh` script handles all of this automatically.

### Why doesn't a single `az group delete` handle everything?

Azure Resource Manager deletes resources in the group bottom-up, but it doesn't know about Kubernetes-level objects (Deployments, PVCs). The PVC lifecycle — including Managed Disk detachment and deletion — is controlled by the CSI driver running inside the cluster. If the cluster is deleted first, that driver never runs.
