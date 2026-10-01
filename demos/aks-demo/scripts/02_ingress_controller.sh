#!/usr/bin/env bash
# =============================================================================
# INGRESS CONTROLLER SETUP
# Logical order: 02
# =============================================================================
# Installs the nginx Ingress Controller via Helm into the AKS cluster.
# This is the Azure / open-source equivalent of the AWS Load Balancer
# Controller (LBC) in the EKS demo.
#
# AWS → Azure mapping
# ─────────────────────────────────────────────────────────────────────────────
# AWS Load Balancer Controller (Helm)  → nginx Ingress Controller (Helm)
# ALB (Application Load Balancer)      → Azure Standard Load Balancer (L4)
#                                          + nginx (L7 proxy inside cluster)
# alb.ingress.kubernetes.io/* annots   → nginx.ingress.kubernetes.io/* annots
# aws-eks-charts Helm repo             → kubernetes/ingress-nginx Helm repo
# IAM policy for LBC                   → Not needed – nginx doesn't call Azure APIs
#
# The EKS demo installs the LBC so that Kubernetes Ingress objects trigger
# the creation of an AWS ALB. Here, nginx plays the same role: it watches
# Ingress objects and acts as the L7 router. Azure automatically creates a
# public Standard Load Balancer for the nginx controller's LoadBalancer Service.
#
# Usage (called by ez_cluster_deploy.sh – not normally run directly):
#   ./02_ingress_controller.sh <resource-group> <cluster-name>
# =============================================================================

set -euo pipefail

RESOURCE_GROUP="${1:?Usage: $0 <resource-group> <cluster-name>}"
CLUSTER_NAME="${2:?Usage: $0 <resource-group> <cluster-name>}"

echo "🔧 Configuring kubectl for cluster: $CLUSTER_NAME"
az aks get-credentials \
  --resource-group "$RESOURCE_GROUP" \
  --name           "$CLUSTER_NAME" \
  --overwrite-existing

# ── Verify Helm is installed ──────────────────────────────────────────────────
if ! command -v helm &>/dev/null; then
  echo "❌ Helm is not installed. Please install Helm and try again."
  echo "   https://helm.sh/docs/intro/install/"
  exit 1
fi

# ── Add the ingress-nginx Helm repo ──────────────────────────────────────────
# Equivalent to the aws-eks-charts repo used by the EKS demo.
echo "📦 Adding ingress-nginx Helm repository..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# ── Install / upgrade nginx Ingress Controller ───────────────────────────────
# We use upgrade --install so this is idempotent (safe to re-run).
# The EKS demo uses terraform helm_release with the same idempotency guarantee.
echo "🚀 Installing ingress-nginx Helm chart..."
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-sku"=standard \
  --set controller.replicaCount=2 \
  --set controller.metrics.enabled=true \
  --wait \
  --timeout 5m

echo "✅ nginx Ingress Controller installed."

# ── Wait for the public IP to be assigned ────────────────────────────────────
# Azure takes ~30–60s to allocate a public IP for the LoadBalancer service.
# The EKS demo has the same wait for ALB DNS propagation.
echo "⏳ Waiting for public IP assignment on ingress-nginx LoadBalancer service..."
for i in $(seq 1 30); do
  INGRESS_IP=$(kubectl get svc ingress-nginx-controller \
    --namespace ingress-nginx \
    --output jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [[ -n "$INGRESS_IP" ]]; then
    echo "✅ Ingress public IP: $INGRESS_IP"
    break
  fi
  echo "  ... still waiting ($i/30)"
  sleep 5
done

if [[ -z "$INGRESS_IP" ]]; then
  echo "⚠️  Public IP not yet assigned. Re-run the deploy script in a moment to get the app URL."
fi
