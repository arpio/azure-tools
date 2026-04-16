/*
  ============================================================================
  PERSISTENT STORAGE – AZURE DISK CSI DRIVER
  Logical order: 03
  ============================================================================
  Azure equivalent of the EKS demo's EBS CSI driver + StorageClass + PVC.

  AWS → Azure mapping
  ──────────────────────────────────────────────────────────────────────────
  EBS CSI Driver (add-on)        → Azure Disk CSI Driver (built into AKS)
  StorageClass (ebs.csi.aws.com) → StorageClass (disk.csi.azure.com)
  EBS gp3 volume                 → Azure Managed Disk (Premium_LRS)
  PVC – ReadWriteOnce, 1Gi       → PVC – ReadWriteOnce, 1Gi  ← identical!
  WaitForFirstConsumer            → WaitForFirstConsumer       ← identical!

  The Azure Disk CSI driver ships with AKS — no add-on installation needed.
  (The EKS demo installs it as a cluster_addons = { aws-ebs-csi-driver = {} } entry.)

  Because StorageClass and PVC are Kubernetes resources (not Azure ARM resources),
  they are applied with kubectl in 03_storage.sh rather than in this Bicep file.
  This file exists as documentation for the YAML manifests that script applies.

  Concepts are identical to the EKS demo:
    StorageClass  → defines what kind of disk to create
    PVC           → a pod's request for storage
    PV            → the actual Managed Disk (created automatically by CSI)

  Flow: Pod references PVC → PVC triggers StorageClass → CSI Driver creates
        Azure Managed Disk → disk attached to node → PV bound to PVC
  ============================================================================
*/

// This file is intentionally documentation-only.
// The actual StorageClass and PVC YAML is applied by scripts/03_storage.sh.
//
// StorageClass YAML reference:
//
//   apiVersion: storage.k8s.io/v1
//   kind: StorageClass
//   metadata:
//     name: azure-disk-storage-class
//     annotations:
//       storageclass.kubernetes.io/is-default-class: "true"
//   provisioner: disk.csi.azure.com
//   reclaimPolicy: Delete
//   volumeBindingMode: WaitForFirstConsumer    # same as EKS demo
//   parameters:
//     skuName: Premium_LRS                     # equivalent to gp3 on AWS
//     fsType: ext4
//     # Encryption at rest is ALWAYS on for Azure Managed Disks (platform key).
//     # No encrypted=true flag needed — unlike the EKS demo's explicit encrypted=true.
//
//   ---
//
//   apiVersion: v1
//   kind: PersistentVolumeClaim
//   metadata:
//     name: azure-disk-pv-claim
//   spec:
//     accessModes: [ReadWriteOnce]
//     storageClassName: azure-disk-storage-class
//     resources:
//       requests:
//         storage: 1Gi

// Outputs referenced by other Bicep files / scripts
// (none – storage is K8s-only, no ARM outputs needed)
