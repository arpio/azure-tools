#!/usr/bin/env bash
# =============================================================================
# DEPLOY THE GUESTBOOK APPLICATION AND LOAD BALANCER
# Logical order: 05
# =============================================================================
# Deploys the same guestbook app as the EKS demo, adapted for Azure:
#   • Same container image  (ghcr.io/setheliot/xyz-demo-app:latest)
#   • Azure Disk PVC instead of EBS PVC (same /app/data mount path)
#   • Cosmos DB instead of DynamoDB (env var names updated)
#   • Azure Key Vault CSI secret volume instead of Secrets Manager CSI
#   • Workload Identity ServiceAccount instead of IRSA ServiceAccount
#   • nginx Ingress instead of ALB Ingress
#
# Usage (called by ez_cluster_deploy.sh):
#   ./05_application.sh <resource-group> <cluster-name> \
#       <app-identity-client-id> <cosmos-endpoint> \
#       <cosmos-database> <cosmos-container> <azure-region> \
#       <kv-name> <tenant-id>
# =============================================================================

set -euo pipefail

RESOURCE_GROUP="${1:?}"
CLUSTER_NAME="${2:?}"
APP_IDENTITY_CLIENT_ID="${3:?}"
COSMOS_ENDPOINT="${4:?}"
COSMOS_DATABASE="${5:?}"
COSMOS_CONTAINER="${6:?}"
AZURE_REGION="${7:?}"
KV_NAME="${8:?}"
TENANT_ID="${9:?}"
SECRET_NAME="${10:?}"

PREFIX_ENV="${CLUSTER_NAME%-cluster}"   # strip "-cluster" suffix to get prefix_env
APP_NAME="guestbook-${PREFIX_ENV}"
SA_NAME="cosmos-${PREFIX_ENV}-sa"

echo "🔧 Configuring kubectl for cluster: $CLUSTER_NAME"
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name           "$CLUSTER_NAME" \
  --overwrite-existing

# ── Kubernetes ServiceAccount ─────────────────────────────────────────────────
# The ServiceAccount is annotated with the Managed Identity client ID.
# Equivalent to the EKS demo's kubernetes_service_account with:
#   eks.amazonaws.com/role-arn = <role ARN>
# Here the equivalent is:
#   azure.workload.identity/client-id = <managed identity client ID>
echo "📦 Applying ServiceAccount..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${SA_NAME}
  namespace: default
  labels:
    # This label tells the AKS Workload Identity webhook to inject credentials
    # into pods that use this ServiceAccount.
    azure.workload.identity/use: "true"
  annotations:
    # Link this ServiceAccount to the Azure Managed Identity.
    # Equivalent to: eks.amazonaws.com/role-arn = <role ARN>
    azure.workload.identity/client-id: "${APP_IDENTITY_CLIENT_ID}"
EOF

# ── SecretProviderClass ───────────────────────────────────────────────────────
# Tells the CSI driver which Key Vault secrets to mount.
# Equivalent to the kubectl_manifest SecretProviderClass in the EKS demo,
# but using provider: azure instead of provider: aws.
echo "📦 Applying SecretProviderClass..."
kubectl apply -f - <<EOF
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: azure-secret-provider
  namespace: default
spec:
  provider: azure
  parameters:
    usePodIdentity:      "false"
    useVMManagedIdentity: "false"
    clientID:            "${APP_IDENTITY_CLIENT_ID}"
    keyvaultName:        "${KV_NAME}"
    tenantId:            "${TENANT_ID}"
    objects: |
      array:
        - |
          objectName: ${SECRET_NAME}
          objectType: secret
          objectVersion: ""
EOF

# ── Kubernetes Deployment ─────────────────────────────────────────────────────
# Same container image as the EKS demo.
# Mounts:
#   - Azure Disk PVC at /app/data  (same path as EBS in EKS demo)
#   - Key Vault secret at /mnt/secrets  (same path as Secrets Manager in EKS demo)
echo "📦 Applying Deployment..."
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${APP_NAME}-deployment
  namespace: default
  labels:
    app: ${APP_NAME}
spec:
  replicas: 3
  selector:
    matchLabels:
      app: ${APP_NAME}
  template:
    metadata:
      labels:
        app: ${APP_NAME}
        # Workload Identity webhook injects Azure credentials into pods with this label
        azure.workload.identity/use: "true"
    spec:
      serviceAccountName: ${SA_NAME}
      containers:
        - name: ${APP_NAME}-container
          # Same image as the EKS demo
          # https://github.com/setheliot/xyz_app_poc/tree/main/src
          image: ghcr.io/setheliot/xyz-demo-app:latest
          ports:
            - containerPort: 80
          resources:
            limits:
              cpu: "0.5"
              memory: "512Mi"
            requests:
              cpu: "250m"
              memory: "50Mi"
          volumeMounts:
            # Azure Disk PVC – same mount path as EBS in EKS demo
            - name: azure-disk-storage
              mountPath: /app/data
            # Key Vault secret – same mount path as Secrets Manager in EKS demo
            - name: secrets-store
              mountPath: /mnt/secrets
              readOnly: true
          env:
            # Cosmos DB connection info – equivalent to DDB_TABLE in EKS demo
            - name: COSMOS_ENDPOINT
              value: "${COSMOS_ENDPOINT}"
            - name: COSMOS_DATABASE
              value: "${COSMOS_DATABASE}"
            - name: COSMOS_CONTAINER
              value: "${COSMOS_CONTAINER}"
            # Azure region – equivalent to AWS_REGION in EKS demo
            - name: AZURE_REGION
              value: "${AZURE_REGION}"
            # Node name via Downward API – identical to EKS demo
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
      volumes:
        # Azure Disk PVC – equivalent to ebs-k8s-attached-storage in EKS demo
        - name: azure-disk-storage
          persistentVolumeClaim:
            claimName: azure-disk-pv-claim
        # Key Vault CSI volume – equivalent to secrets-store in EKS demo
        - name: secrets-store
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true
            volumeAttributes:
              secretProviderClass: azure-secret-provider
EOF

# ── Kubernetes Service ────────────────────────────────────────────────────────
# ClusterIP: traffic enters via the Ingress, not directly.
# Equivalent to kubernetes_service_v1.service_alb in modules/alb/alb.tf.
echo "📦 Applying Service..."
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${PREFIX_ENV}-service
  namespace: default
  labels:
    app: ${APP_NAME}
spec:
  selector:
    app: ${APP_NAME}
  ports:
    - port: 8080
      targetPort: 80
  type: ClusterIP
EOF

# ── Kubernetes Ingress ────────────────────────────────────────────────────────
# Routes external HTTP traffic to the guestbook Service.
# Equivalent to kubernetes_ingress_v1.ingress_alb in modules/alb/alb.tf,
# but using ingressClassName: nginx instead of ingressClassName: alb.
echo "📦 Applying Ingress..."
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${PREFIX_ENV}-ingress
  namespace: default
  annotations:
    # nginx equivalent of alb.ingress.kubernetes.io/scheme: internet-facing
    # (the nginx controller's LoadBalancer Service is already internet-facing)
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  # nginx IngressClass – equivalent to ingress_class_name = "alb" in EKS demo
  ingressClassName: nginx
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${PREFIX_ENV}-service
                port:
                  number: 8080
EOF

echo "✅ Application resources applied."
echo "   Deployment, Service, and Ingress created for app: ${APP_NAME}"
