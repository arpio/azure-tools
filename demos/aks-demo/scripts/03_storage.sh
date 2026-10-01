#!/usr/bin/env bash
# =============================================================================
# PERSISTENT STORAGE – AZURE DISK CSI
# Logical order: 03
# =============================================================================
# Applies a StorageClass and PersistentVolumeClaim to the AKS cluster.
# Equivalent to the EKS demo's Terraform kubernetes_storage_class and
# kubernetes_persistent_volume_claim_v1 resources.
#
# AWS → Azure mapping
# ─────────────────────────────────────────────────────────────────────────────
# EBS CSI Driver (add-on install)  → Azure Disk CSI (built into AKS – no install)
# StorageClass provisioner         → disk.csi.azure.com  (vs ebs.csi.aws.com)
# gp3 / encrypted=true             → Premium_LRS (always encrypted on Azure)
# WaitForFirstConsumer             → WaitForFirstConsumer (identical behavior)
#
# Usage (called by ez_cluster_deploy.sh):
#   ./03_storage.sh <resource-group> <cluster-name>
# =============================================================================

set -euo pipefail

RESOURCE_GROUP="${1:?Usage: $0 <resource-group> <cluster-name>}"
CLUSTER_NAME="${2:?Usage: $0 <resource-group> <cluster-name>}"

echo "🔧 Configuring kubectl for cluster: $CLUSTER_NAME"
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name           "$CLUSTER_NAME" \
  --overwrite-existing

# ── StorageClass ──────────────────────────────────────────────────────────────
# Uses disk.csi.azure.com (Azure Disk CSI, built into AKS).
# Premium_LRS = SSD – equivalent to gp3 on AWS.
# WaitForFirstConsumer: don't create the disk until a pod is scheduled.
#   Critical: ensures disk and pod land in the same availability zone.
#   Without this, you risk: disk in Zone 1, pod in Zone 2 = mount failure.
#   Identical to the EKS demo's WaitForFirstConsumer setting.
# Encryption at rest is ALWAYS on for Azure Managed Disks (platform-managed key).
#   No encrypted=true flag needed – unlike the EKS demo's explicit encrypted=true.
echo "📦 Applying StorageClass..."
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: azure-disk-storage-class
  annotations:
    # Make this the default – PVCs without an explicit class will use this.
    # Same as the EKS demo's storageclass.kubernetes.io/is-default-class: "true".
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: disk.csi.azure.com
reclaimPolicy: Delete
volumeBindingMode: WaitForFirstConsumer
parameters:
  skuName: Premium_LRS
  fsType: ext4
EOF

# ── PersistentVolumeClaim ─────────────────────────────────────────────────────
# A pod's request for storage. The actual Managed Disk is NOT created until
# a pod actually uses this PVC (WaitForFirstConsumer).
# ReadWriteOnce: volume can be mounted by ONE node at a time.
#   Azure Managed Disks are block devices – same constraint as EBS on EKS.
#   (For multi-node access, use Azure Files + ReadWriteMany instead.)
echo "📦 Applying PersistentVolumeClaim..."
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: azure-disk-pv-claim
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: azure-disk-storage-class
  resources:
    requests:
      storage: 1Gi
EOF

# What happens next (same flow as EKS demo):
# 1. PVC is created with status: Pending (no disk yet)
# 2. When a pod references this PVC, the scheduler picks a node
# 3. Azure Disk CSI driver creates a Managed Disk in the node's AZ
# 4. CSI driver attaches the disk to the node VM
# 5. PVC status changes to Bound
echo "✅ StorageClass and PVC applied (PVC will remain Pending until a pod uses it – this is expected)."
