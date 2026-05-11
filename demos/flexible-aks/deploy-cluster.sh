#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Arpio AKS Cluster Deployment Script
# =============================================================================
# Deploys an AKS cluster in one of three network configurations:
#   managed-network  - Azure-managed VNet, API server VNet integration, public delegate
#   custom-network   - BYO VNet, public API, public delegate
#   private-network  - BYO VNet, private API, private delegate
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BICEP_DIR="${SCRIPT_DIR}/bicep"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}${BOLD}→${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}!${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}$*${RESET}"; echo -e "${BOLD}$(printf '%.0s─' {1..60})${RESET}"; }

prompt() {
  # prompt <var_name> <display_text> [default]
  local var="$1"
  local msg="$2"
  local default="${3:-}"
  local input

  if [[ -n "$default" ]]; then
    read -rp "$(echo -e "${BOLD}${msg}${RESET} [${default}]: ")" input
    input="${input:-$default}"
  else
    read -rp "$(echo -e "${BOLD}${msg}${RESET}: ")" input
    while [[ -z "$input" ]]; do
      warn "Value required."
      read -rp "$(echo -e "${BOLD}${msg}${RESET}: ")" input
    done
  fi

  printf -v "$var" '%s' "$input"
}

pick_from_list() {
  # pick_from_list <var_name> <prompt> <item1> [item2 ...]
  # Sets <var_name> to the selected value and PICK_IDX to the 0-based index.
  local var="$1"
  local msg="$2"
  shift 2
  local items=("$@")
  local i

  echo -e "\n${BOLD}${msg}${RESET}"
  for i in "${!items[@]}"; do
    echo -e "  ${BOLD}$((i+1)).${RESET} ${items[$i]}"
  done

  local choice
  while true; do
    read -rp "$(echo -e "${BOLD}Choice [1-${#items[@]}]${RESET}: ")" choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#items[@]} )); then
      printf -v "$var" '%s' "${items[$((choice-1))]}"
      PICK_IDX=$((choice-1))
      return
    fi
    warn "Enter a number between 1 and ${#items[@]}."
  done
}

confirm() {
  # confirm <message> — returns 0 for yes, 1 for no
  local answer
  read -rp "$(echo -e "${BOLD}$1 [y/N]${RESET}: ")" answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

derive_suffix() {
  # Deterministic 6-char suffix from prefix + subscription ID + username
  local raw="${1}${2}${3}"
  echo -n "$raw" | openssl dgst -sha256 | awk '{print $2}' | cut -c1-6
}

# -----------------------------------------------------------------------------
# Step 1: Authentication
# -----------------------------------------------------------------------------

header "Step 1: Azure Authentication"

if ! az account show &>/dev/null; then
  warn "No active Azure login detected."
  info "Launching browser login..."
  az login
fi

CURRENT_USER_UPN=$(az ad signed-in-user show --query userPrincipalName -o tsv 2>/dev/null || true)
CURRENT_USER_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)

if [[ -z "$CURRENT_USER_UPN" ]] || [[ -z "$CURRENT_USER_ID" ]]; then
  error "Could not determine the logged-in user. Ensure your account has Azure AD read permissions."
  exit 1
fi

success "Logged in as: ${CURRENT_USER_UPN}"

# -----------------------------------------------------------------------------
# Step 2: Subscription
# -----------------------------------------------------------------------------

header "Step 2: Subscription"

info "Fetching available subscriptions..."
mapfile -t SUB_NAMES < <(az account list --query "[?state=='Enabled'].name" -o tsv)
mapfile -t SUB_IDS   < <(az account list --query "[?state=='Enabled'].id"   -o tsv)

if [[ ${#SUB_NAMES[@]} -eq 0 ]]; then
  error "No subscriptions found for the current login."
  exit 1
fi

# Build display list with ID hint
DISPLAY_SUBS=()
for i in "${!SUB_NAMES[@]}"; do
  DISPLAY_SUBS+=("${SUB_NAMES[$i]} (${SUB_IDS[$i]})")
done

pick_from_list SELECTED_SUB_DISPLAY "Select a subscription:" "${DISPLAY_SUBS[@]}"
SUBSCRIPTION_ID="${SUB_IDS[$PICK_IDX]}"
SUBSCRIPTION_NAME="${SUB_NAMES[$PICK_IDX]}"

az account set --subscription "$SUBSCRIPTION_ID"
success "Using subscription: ${SUBSCRIPTION_NAME} (${SUBSCRIPTION_ID})"

# -----------------------------------------------------------------------------
# Step 3: Region
# -----------------------------------------------------------------------------

header "Step 3: Region"
prompt LOCATION "Azure region (e.g. eastus, westeurope, australiaeast)"
success "Region: ${LOCATION}"

# -----------------------------------------------------------------------------
# Step 4: Network Configuration
# -----------------------------------------------------------------------------

header "Step 4: Network Configuration"

cat <<EOF

  ${BOLD}managed-network${RESET}
    Azure manages the VNet. API server VNet integration enabled.
    Public API endpoint. Public Arpio delegate.

  ${BOLD}custom-network${RESET}
    You provide the VNet (script creates it). No API server VNet integration.
    Public API endpoint. Public Arpio delegate.

  ${BOLD}private-network${RESET}
    You provide the VNet (script creates it). No API server VNet integration.
    No public API endpoint. Private Arpio delegate required.

EOF

pick_from_list NETWORK_CONFIG "Select a network configuration:" \
  "managed-network" \
  "custom-network" \
  "private-network"

success "Network configuration: ${NETWORK_CONFIG}"

# -----------------------------------------------------------------------------
# Step 5: Networking Model (CNI / Kubenet)
# -----------------------------------------------------------------------------

header "Step 5: Networking Model"

if [[ "$NETWORK_CONFIG" == "managed-network" ]]; then
  NETWORK_PLUGIN="azure"
  NETWORK_PLUGIN_MODE="overlay"
  warn "managed-network requires Azure CNI Overlay. Kubenet is not supported with API server VNet integration."
  info  "Network plugin set to: Azure CNI Overlay"
else
  cat <<EOF

  ${BOLD}azure-cni-overlay${RESET}
    Nodes use VNet IPs. Pods use a private overlay CIDR (no VNet IP consumption).
    Recommended for most workloads.

  ${BOLD}kubenet${RESET}
    Nodes use VNet IPs. Pods use a private CIDR routed via Azure-managed UDRs.
    Simpler but lacks Azure Network Policy support and has UDR management overhead.

EOF
  pick_from_list NETWORK_MODEL "Select a networking model:" \
    "azure-cni-overlay" \
    "kubenet"

  if [[ "$NETWORK_MODEL" == "azure-cni-overlay" ]]; then
    NETWORK_PLUGIN="azure"
    NETWORK_PLUGIN_MODE="overlay"
  else
    NETWORK_PLUGIN="kubenet"
    NETWORK_PLUGIN_MODE=""
  fi

  success "Networking model: ${NETWORK_MODEL}"
fi

# Network policy — only applicable to Azure CNI Overlay
if [[ "$NETWORK_PLUGIN_MODE" == "overlay" ]]; then
  cat <<EOF

  ${BOLD}azure${RESET} (default)
    Azure Network Policy Manager.

  ${BOLD}cilium${RESET}
    eBPF-based network policy with advanced observability and load balancing.
    Requires Azure CNI Overlay (already selected).

EOF
  pick_from_list NETWORK_POLICY "Select a network policy engine:" \
    "azure" \
    "cilium"
  success "Network policy: ${NETWORK_POLICY}"
else
  NETWORK_POLICY="azure"
fi

# -----------------------------------------------------------------------------
# Step 6: Kubernetes Authentication
# -----------------------------------------------------------------------------

header "Step 6: Kubernetes Authentication"

cat <<EOF

  ${BOLD}entra${RESET}
    Users authenticate via Azure Entra ID tokens.
    Azure RBAC manages cluster access. An Entra admin group will be created
    and the current user added automatically.

  ${BOLD}classic${RESET}
    Local cluster admin certificate and kubeconfig.
    No Entra dependency.

EOF

pick_from_list K8S_AUTH "Select Kubernetes authentication:" \
  "entra" \
  "classic"

success "Kubernetes auth: ${K8S_AUTH}"

# -----------------------------------------------------------------------------
# Step 7: Managed Identity
# -----------------------------------------------------------------------------

header "Step 7: Managed Identity"

cat <<EOF

  ${BOLD}system-assigned${RESET}
    Identity is created and managed automatically with the cluster.
    Deleted when the cluster is deleted.

  ${BOLD}user-assigned${RESET}
    Script creates a managed identity using the naming convention.
    Persists independently of the cluster. Current user is assigned
    Managed Identity Operator on the identity.

EOF

pick_from_list IDENTITY_TYPE "Select managed identity type:" \
  "system-assigned" \
  "user-assigned"

# Bicep @allowed values use PascalCase; shell conditionals use the lowercase form above
IDENTITY_TYPE_BICEP=$([[ "$IDENTITY_TYPE" == "user-assigned" ]] && echo "UserAssigned" || echo "SystemAssigned")

success "Managed identity: ${IDENTITY_TYPE}"

# -----------------------------------------------------------------------------
# Step 8: Resource Prefix
# -----------------------------------------------------------------------------

header "Step 8: Resource Naming"

prompt PREFIX "Resource prefix (2+ chars, lowercase alphanumeric and hyphens, e.g. ar, arpio, myteam-aks)"

# Validate prefix: lowercase alphanumeric and hyphens, no leading/trailing hyphen, min 2 chars
if ! [[ "$PREFIX" =~ ^[a-z0-9][a-z0-9-]*[a-z0-9]$ ]]; then
  error "Prefix must be at least 2 characters, lowercase alphanumeric with hyphens, no leading/trailing hyphens."
  exit 1
fi

SUFFIX=$(derive_suffix "$PREFIX" "$SUBSCRIPTION_ID" "$CURRENT_USER_UPN")

# Resource names
RG_MAIN="${PREFIX}-rg-${SUFFIX}"
RG_INFRA="${PREFIX}-infra-rg-${SUFFIX}"
CLUSTER_NAME="${PREFIX}-aks-${SUFFIX}"
VNET_NAME="${PREFIX}-vnet-${SUFFIX}"
SUBNET_NAME="${PREFIX}-subnet-${SUFFIX}"
IDENTITY_NAME="${PREFIX}-id-${SUFFIX}"
ENTRA_GROUP_NAME="${PREFIX}-admins-${SUFFIX}"

echo ""
info "Derived resource names:"
echo "  Suffix:            ${SUFFIX}"
echo "  Main RG:           ${RG_MAIN}"
if [[ "$NETWORK_CONFIG" != "managed-network" ]]; then
  echo "  Infra RG:          ${RG_INFRA}"
  echo "  VNet:              ${VNET_NAME}"
  echo "  Subnet:            ${SUBNET_NAME}"
fi
echo "  Cluster:           ${CLUSTER_NAME}"
if [[ "$IDENTITY_TYPE" == "user-assigned" ]]; then
  echo "  Managed Identity:  ${IDENTITY_NAME}"
fi
if [[ "$K8S_AUTH" == "entra" ]]; then
  echo "  Entra Admin Group: ${ENTRA_GROUP_NAME}"
fi

# -----------------------------------------------------------------------------
# Step 9: Node Pool
# -----------------------------------------------------------------------------

header "Step 9: Node Pool"

prompt VM_SKU      "Node VM SKU"    "Standard_D2s_v3"
prompt NODE_COUNT  "Node count"     "2"

if ! [[ "$NODE_COUNT" =~ ^[0-9]+$ ]] || (( NODE_COUNT < 1 )); then
  error "Node count must be a positive integer."
  exit 1
fi

success "Node pool: ${NODE_COUNT}x ${VM_SKU}"

# -----------------------------------------------------------------------------
# Summary + Confirmation
# -----------------------------------------------------------------------------

header "Deployment Summary"

cat <<EOF

  ${BOLD}Subscription:${RESET}       ${SUBSCRIPTION_NAME}
  ${BOLD}Region:${RESET}             ${LOCATION}
  ${BOLD}Configuration:${RESET}      ${NETWORK_CONFIG}
  ${BOLD}Network plugin:${RESET}     ${NETWORK_PLUGIN}${NETWORK_PLUGIN_MODE:+ (${NETWORK_PLUGIN_MODE})}
  ${BOLD}Network policy:${RESET}     ${NETWORK_POLICY}
  ${BOLD}Kubernetes auth:${RESET}    ${K8S_AUTH}
  ${BOLD}Managed identity:${RESET}   ${IDENTITY_TYPE}
  ${BOLD}Prefix / Suffix:${RESET}    ${PREFIX} / ${SUFFIX}
  ${BOLD}Main RG:${RESET}            ${RG_MAIN}
EOF

if [[ "$NETWORK_CONFIG" != "managed-network" ]]; then
cat <<EOF
  ${BOLD}Infra RG:${RESET}           ${RG_INFRA}
  ${BOLD}VNet:${RESET}               ${VNET_NAME}
  ${BOLD}Subnet:${RESET}             ${SUBNET_NAME}
EOF
fi

cat <<EOF
  ${BOLD}Cluster:${RESET}            ${CLUSTER_NAME}
  ${BOLD}Node pool:${RESET}          ${NODE_COUNT}x ${VM_SKU}
EOF

if [[ "$IDENTITY_TYPE" == "user-assigned" ]]; then
  echo -e "  ${BOLD}Identity:${RESET}           ${IDENTITY_NAME}"
fi
if [[ "$K8S_AUTH" == "entra" ]]; then
  echo -e "  ${BOLD}Entra group:${RESET}        ${ENTRA_GROUP_NAME}"
fi

echo ""

if ! confirm "Proceed with deployment?"; then
  info "Deployment cancelled."
  exit 0
fi

# -----------------------------------------------------------------------------
# Resource Groups
# -----------------------------------------------------------------------------

header "Creating Resource Groups"

info "Creating main resource group: ${RG_MAIN}"
az group create --name "$RG_MAIN" --location "$LOCATION" --output none
success "Created: ${RG_MAIN}"

if [[ "$NETWORK_CONFIG" != "managed-network" ]]; then
  info "Creating infra resource group: ${RG_INFRA}"
  az group create --name "$RG_INFRA" --location "$LOCATION" --output none
  success "Created: ${RG_INFRA}"
fi

# -----------------------------------------------------------------------------
# User-Assigned Managed Identity
# -----------------------------------------------------------------------------

if [[ "$IDENTITY_TYPE" == "user-assigned" ]]; then
  header "Creating Managed Identity"

  info "Creating user-assigned managed identity: ${IDENTITY_NAME}"
  az deployment group create \
    --resource-group "$RG_MAIN" \
    --template-file "${BICEP_DIR}/modules/identity.bicep" \
    --parameters \
        identityName="$IDENTITY_NAME" \
        location="$LOCATION" \
    --output none

  IDENTITY_RESOURCE_ID=$(az identity show \
    --name "$IDENTITY_NAME" \
    --resource-group "$RG_MAIN" \
    --query id -o tsv)

  success "Created identity: ${IDENTITY_NAME}"

  info "Assigning Managed Identity Operator to current user..."
  az role assignment create \
    --assignee "$CURRENT_USER_ID" \
    --role "Managed Identity Operator" \
    --scope "$IDENTITY_RESOURCE_ID" \
    --output none
  success "Role assigned: Managed Identity Operator → ${CURRENT_USER_UPN}"
fi

# -----------------------------------------------------------------------------
# Entra Admin Group
# -----------------------------------------------------------------------------

if [[ "$K8S_AUTH" == "entra" ]]; then
  header "Creating Entra Admin Group"

  info "Creating Entra group: ${ENTRA_GROUP_NAME}"
  ENTRA_GROUP_ID=$(az ad group create \
    --display-name "$ENTRA_GROUP_NAME" \
    --mail-nickname "$ENTRA_GROUP_NAME" \
    --query id -o tsv)
  success "Created group: ${ENTRA_GROUP_NAME} (${ENTRA_GROUP_ID})"

  info "Adding current user to group..."
  ALREADY_MEMBER=$(az ad group member check \
    --group "$ENTRA_GROUP_ID" \
    --member-id "$CURRENT_USER_ID" \
    --query value -o tsv 2>/dev/null || echo "false")

  if [[ "$ALREADY_MEMBER" == "true" ]]; then
    success "${CURRENT_USER_UPN} is already a member of ${ENTRA_GROUP_NAME} — skipping."
  elif ! ADD_ERR=$(az ad group member add \
      --group "$ENTRA_GROUP_ID" \
      --member-id "$CURRENT_USER_ID" 2>&1); then
    if echo "$ADD_ERR" | grep -qi "already exist"; then
      success "${CURRENT_USER_UPN} is already a member of ${ENTRA_GROUP_NAME} — skipping."
    else
      echo "$ADD_ERR" >&2
      error "Failed to add ${CURRENT_USER_UPN} to ${ENTRA_GROUP_NAME}."
      warn "This typically requires 'Group.ReadWrite.All' or 'Directory.ReadWrite.All' in Entra ID."
      warn "Ask your tenant admin to grant those permissions, then run manually:"
      echo -e "    az ad group member add --group \"${ENTRA_GROUP_ID}\" --member-id \"${CURRENT_USER_ID}\""
      exit 1
    fi
  else
    echo "$ADD_ERR"
    success "Added ${CURRENT_USER_UPN} to ${ENTRA_GROUP_NAME}"
  fi
fi

# -----------------------------------------------------------------------------
# Networking (Configs B and C)
# -----------------------------------------------------------------------------

if [[ "$NETWORK_CONFIG" != "managed-network" ]]; then
  header "Provisioning Network"

  info "Deploying VNet and subnet into ${RG_INFRA}..."
  az deployment group create \
    --resource-group "$RG_INFRA" \
    --template-file "${BICEP_DIR}/modules/network.bicep" \
    --parameters \
        vnetName="$VNET_NAME" \
        subnetName="$SUBNET_NAME" \
        location="$LOCATION" \
    --output none

  SUBNET_ID=$(az network vnet subnet show \
    --resource-group "$RG_INFRA" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --query id -o tsv)

  success "VNet and subnet ready: ${VNET_NAME} / ${SUBNET_NAME}"
fi

# -----------------------------------------------------------------------------
# AKS Cluster
# -----------------------------------------------------------------------------

header "Deploying AKS Cluster"

info "Deploying cluster: ${CLUSTER_NAME} — this may take 5–10 minutes..."

# Build parameter set for Bicep
BICEP_PARAMS=(
  clusterName="$CLUSTER_NAME"
  location="$LOCATION"
  networkConfig="$NETWORK_CONFIG"
  networkPlugin="$NETWORK_PLUGIN"
  networkPolicy="$NETWORK_POLICY"
  k8sAuth="$K8S_AUTH"
  identityType="$IDENTITY_TYPE_BICEP"
  nodeVmSku="$VM_SKU"
  nodeCount="$NODE_COUNT"
)

if [[ "$NETWORK_PLUGIN_MODE" == "overlay" ]]; then
  BICEP_PARAMS+=(networkPluginMode="overlay")
fi

if [[ "$NETWORK_CONFIG" != "managed-network" ]]; then
  BICEP_PARAMS+=(subnetId="$SUBNET_ID")
fi

if [[ "$IDENTITY_TYPE" == "user-assigned" ]]; then
  BICEP_PARAMS+=(userAssignedIdentityId="$IDENTITY_RESOURCE_ID")
fi

if [[ "$K8S_AUTH" == "entra" ]]; then
  BICEP_PARAMS+=(entraAdminGroupId="$ENTRA_GROUP_ID")
fi

az deployment group create \
  --resource-group "$RG_MAIN" \
  --template-file "${BICEP_DIR}/main.bicep" \
  --parameters "${BICEP_PARAMS[@]}" \
  --output none

success "Cluster deployed: ${CLUSTER_NAME}"

# -----------------------------------------------------------------------------
# kubeconfig
# -----------------------------------------------------------------------------

header "Fetching kubeconfig"

if [[ "$K8S_AUTH" == "entra" ]]; then
  az aks get-credentials \
    --resource-group "$RG_MAIN" \
    --name "$CLUSTER_NAME" \
    --overwrite-existing
  info "Note: kubectl commands will use Entra authentication via your current az login."
else
  az aks get-credentials \
    --resource-group "$RG_MAIN" \
    --name "$CLUSTER_NAME" \
    --overwrite-existing \
    --admin
fi

success "kubeconfig updated. Cluster context: ${CLUSTER_NAME}"

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------

header "Deployment Complete"

cat <<EOF

  ${GREEN}${BOLD}AKS cluster is ready.${RESET}

  ${BOLD}Cluster:${RESET}       ${CLUSTER_NAME}
  ${BOLD}Config:${RESET}        ${NETWORK_CONFIG}
  ${BOLD}Resource group:${RESET} ${RG_MAIN}
EOF

if [[ "$NETWORK_CONFIG" != "managed-network" ]]; then
  echo -e "  ${BOLD}Infra RG:${RESET}      ${RG_INFRA}"
fi

if [[ "$NETWORK_CONFIG" == "private-network" ]]; then
  echo ""
  warn "This is a private cluster. Install the Arpio private delegate inside the cluster VNet."
  warn "The public Arpio delegate cannot reach private API endpoints."
fi

echo ""
info "Test connectivity:  kubectl get nodes"
echo ""
