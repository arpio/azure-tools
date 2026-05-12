#!/usr/bin/env bash
#set -x
set -euo pipefail

# =============================================================================
# Arpio AKS Cluster Deployment Script
# =============================================================================
# Deploys an AKS cluster in one of three network configurations:
#   managed-network  - Azure-managed VNet, API server VNet integration, public delegate
#   custom-network   - BYO VNet, public API, public delegate
#   private-network  - BYO VNet, private API, private delegate
#
# Usage:
#   ./deploy-cluster.sh                        # fully interactive
#   ./deploy-cluster.sh --params <params-file> # pre-populate from file
# =============================================================================

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

PARAMS_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --params)
      [[ $# -ge 2 ]] || { echo "Error: --params requires a file argument" >&2; exit 1; }
      PARAMS_FILE="$2"
      shift 2
      ;;
    *)
      echo "Usage: $(basename "${BASH_SOURCE[0]}") [--params <params-file>]" >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BICEP_DIR="${SCRIPT_DIR}/bicep"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

RED=$'\033[0;31m'
YELLOW=$'\033[1;33m'
GREEN=$'\033[0;32m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
RESET=$'\033[0m'

info()    { echo -e "${CYAN}${BOLD}→${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}${BOLD}!${RESET} $*"; }
error()   { echo -e "${RED}${BOLD}✗${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}$*${RESET}"; echo -e "${BOLD}$(printf '%.0s─' {1..60})${RESET}"; }
from_params() { echo -e "${CYAN}${BOLD}→${RESET} ${BOLD}${1}:${RESET} ${2} ${YELLOW}(params)${RESET}"; }

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
  # confirm <message> — default no, returns 0 for yes, 1 for no
  local answer
  read -rp "$(echo -e "${BOLD}$1 [y/N]${RESET}: ")" answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

confirm_yes() {
  # confirm_yes <message> — default yes, returns 0 for yes, 1 for no
  local answer
  read -rp "$(echo -e "${BOLD}$1 [Y/n]${RESET}: ")" answer
  [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
}

derive_suffix() {
  # Deterministic 6-char suffix from prefix + subscription ID + username
  local raw="${1}${2}${3}"
  echo -n "$raw" | openssl dgst -sha256 | awk '{print $2}' | cut -c1-6
}

# -----------------------------------------------------------------------------
# Params file — load and validate
# -----------------------------------------------------------------------------

if [[ -n "$PARAMS_FILE" ]]; then
  if [[ ! -f "$PARAMS_FILE" ]]; then
    error "Params file not found: ${PARAMS_FILE}"
    exit 1
  fi
  # shellcheck source=/dev/null
  source "$PARAMS_FILE"
  info "Loaded parameters from: ${PARAMS_FILE}"

  # Validate allowed values for any pre-set parameters
  if [[ -n "${NETWORK_CONFIG:-}" ]]; then
    [[ "$NETWORK_CONFIG" =~ ^(managed-network|custom-network|private-network)$ ]] || {
      error "NETWORK_CONFIG must be: managed-network | custom-network | private-network"
      exit 1
    }
  fi
  if [[ -n "${NETWORK_MODEL:-}" ]]; then
    [[ "$NETWORK_MODEL" =~ ^(azure-cni-overlay|kubenet)$ ]] || {
      error "NETWORK_MODEL must be: azure-cni-overlay | kubenet"
      exit 1
    }
  fi
  if [[ -n "${NETWORK_POLICY:-}" ]]; then
    [[ "$NETWORK_POLICY" =~ ^(azure|cilium)$ ]] || {
      error "NETWORK_POLICY must be: azure | cilium"
      exit 1
    }
  fi
  if [[ -n "${K8S_AUTH:-}" ]]; then
    [[ "$K8S_AUTH" =~ ^(entra|classic)$ ]] || {
      error "K8S_AUTH must be: entra | classic"
      exit 1
    }
  fi
  if [[ -n "${IDENTITY_TYPE:-}" ]]; then
    [[ "$IDENTITY_TYPE" =~ ^(system-assigned|user-assigned)$ ]] || {
      error "IDENTITY_TYPE must be: system-assigned | user-assigned"
      exit 1
    }
  fi
  if [[ -n "${ENTRA_ADMIN_ENABLED:-}" ]]; then
    [[ "$ENTRA_ADMIN_ENABLED" =~ ^(true|false)$ ]] || {
      error "ENTRA_ADMIN_ENABLED must be: true | false"
      exit 1
    }
  fi
  if [[ -n "${NODE_COUNT:-}" ]]; then
    [[ "$NODE_COUNT" =~ ^[0-9]+$ ]] && (( NODE_COUNT >= 1 )) || {
      error "NODE_COUNT must be a positive integer"
      exit 1
    }
  fi
  if [[ -n "${PREFIX:-}" ]]; then
    [[ "$PREFIX" =~ ^[a-z][a-z0-9]+$ ]] || {
      error "PREFIX must be 2+ characters, lowercase letters and numbers only (no hyphens). Example: arpio, myteam, staging."
      exit 1
    }
  fi
fi

# -----------------------------------------------------------------------------
# Step 1: Authentication
# -----------------------------------------------------------------------------

header "Step 1: Azure Authentication"

if ! az account show &>/dev/null; then
  warn "No active Azure login detected."
  info "Launching browser login..."
  az login
fi

CURRENT_USER_UPN=$(az ad signed-in-user show --query userPrincipalName -o tsv 2>/dev/null | tr -d '\r' || true)
CURRENT_USER_ID=$(az ad signed-in-user show --query id -o tsv 2>/dev/null | tr -d '\r' || true)

if [[ -z "$CURRENT_USER_UPN" ]] || [[ -z "$CURRENT_USER_ID" ]]; then
  error "Could not determine the logged-in user. Ensure your account has Azure AD read permissions."
  exit 1
fi

success "Logged in as: ${CURRENT_USER_UPN}"

# -----------------------------------------------------------------------------
# Step 2: Subscription
# -----------------------------------------------------------------------------

header "Step 2: Subscription"

if [[ -n "${SUBSCRIPTION_ID:-}" ]]; then
  info "Fetching subscription details..."
  SUBSCRIPTION_NAME=$(az account show \
    --subscription "$SUBSCRIPTION_ID" \
    --query name -o tsv --only-show-errors 2>/dev/null | tr -d '\r' || true)
  if [[ -z "$SUBSCRIPTION_NAME" ]]; then
    error "Subscription '${SUBSCRIPTION_ID}' not found or not accessible."
    exit 1
  fi
  az account set --subscription "$SUBSCRIPTION_ID" --output none
  from_params "Subscription" "${SUBSCRIPTION_NAME} (${SUBSCRIPTION_ID})"
else
  info "Fetching available subscriptions..."
  mapfile -t SUB_NAMES < <(az account list --query "[?state=='Enabled'].name" -o tsv | tr -d '\r')
  mapfile -t SUB_IDS   < <(az account list --query "[?state=='Enabled'].id"   -o tsv | tr -d '\r')

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
fi

success "Using subscription: ${SUBSCRIPTION_NAME} (${SUBSCRIPTION_ID})"

# -----------------------------------------------------------------------------
# Step 3: Region
# -----------------------------------------------------------------------------

header "Step 3: Region"

if [[ -n "${LOCATION:-}" ]]; then
  from_params "Region" "$LOCATION"
else
  prompt LOCATION "Azure region (e.g. eastus, westeurope, australiaeast)"
fi

info "Validating region..."
VALID_LOCATION=$(az account list-locations \
  --query "[?name=='${LOCATION}'].name" -o tsv --only-show-errors 2>/dev/null | tr -d '\r' || true)
if [[ -z "$VALID_LOCATION" ]]; then
  error "Region '${LOCATION}' is not a valid Azure region for this subscription."
  info "Run: az account list-locations --query \"[].name\" -o tsv"
  exit 1
fi

success "Region: ${LOCATION}"

# -----------------------------------------------------------------------------
# Step 4: Network Configuration
# -----------------------------------------------------------------------------

header "Step 4: Network Configuration"

_nc_from_params=false
if [[ -n "${NETWORK_CONFIG:-}" ]]; then
  _nc_from_params=true
else
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
fi

case "$NETWORK_CONFIG" in
  managed-network) NETWORK_CONFIG_DESC="Azure-managed VNet, API server VNet integration, public API endpoint, public delegate" ;;
  custom-network)  NETWORK_CONFIG_DESC="script-created VNet, public API endpoint, public delegate" ;;
  private-network) NETWORK_CONFIG_DESC="script-created VNet, private API endpoint, private delegate required" ;;
  *) error "Invalid network configuration: '${NETWORK_CONFIG}'. Allowed: managed-network | custom-network | private-network"; exit 1 ;;
esac

[[ "$_nc_from_params" == "true" ]] && from_params "Network configuration" "${NETWORK_CONFIG} — ${NETWORK_CONFIG_DESC}"
success "Network configuration: ${NETWORK_CONFIG} — ${NETWORK_CONFIG_DESC}"

# -----------------------------------------------------------------------------
# Step 5: Networking Model (CNI / Kubenet)
# -----------------------------------------------------------------------------

header "Step 5: Networking Model"

if [[ "$NETWORK_CONFIG" == "managed-network" ]]; then
  NETWORK_PLUGIN="azure"
  NETWORK_PLUGIN_MODE="overlay"
  if [[ -n "${NETWORK_MODEL:-}" ]]; then
    warn "NETWORK_MODEL is ignored for managed-network (always Azure CNI Overlay)."
  fi
  info "Network plugin set to: Azure CNI Overlay (required for managed-network)"
elif [[ -n "${NETWORK_MODEL:-}" ]]; then
  if [[ "$NETWORK_MODEL" == "azure-cni-overlay" ]]; then
    NETWORK_PLUGIN="azure"
    NETWORK_PLUGIN_MODE="overlay"
  else
    NETWORK_PLUGIN="kubenet"
    NETWORK_PLUGIN_MODE=""
  fi
  from_params "Networking model" "$NETWORK_MODEL"
  success "Networking model: ${NETWORK_MODEL}"
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
  if [[ -n "${NETWORK_POLICY:-}" ]]; then
    from_params "Network policy" "$NETWORK_POLICY"
  else
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
  fi
else
  NETWORK_POLICY="azure"
fi

# -----------------------------------------------------------------------------
# Step 6: Kubernetes Authentication
# -----------------------------------------------------------------------------

header "Step 6: Kubernetes Authentication"

if [[ -n "${K8S_AUTH:-}" ]]; then
  from_params "Kubernetes auth" "$K8S_AUTH"
else
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
fi

success "Kubernetes auth: ${K8S_AUTH}"

if [[ "$K8S_AUTH" == "entra" ]]; then
  if [[ -n "${ENTRA_ADMIN_ENABLED:-}" ]]; then
    from_params "Entra admin group" "$ENTRA_ADMIN_ENABLED"
    [[ "$ENTRA_ADMIN_ENABLED" == "false" ]] && \
      warn "Skipping Entra admin group. Grant cluster access manually via Azure RBAC after deployment."
  else
    ENTRA_ADMIN_ENABLED=false
    echo ""
    if confirm_yes "Grant ${CURRENT_USER_UPN} cluster-admin access via a new Entra admin group?"; then
      ENTRA_ADMIN_ENABLED=true
    else
      warn "Skipping Entra admin group. Grant cluster access manually via Azure RBAC after deployment."
    fi
  fi
else
  ENTRA_ADMIN_ENABLED=false
fi

# -----------------------------------------------------------------------------
# Step 7: Managed Identity
# -----------------------------------------------------------------------------

header "Step 7: Managed Identity"

if [[ -n "${IDENTITY_TYPE:-}" ]]; then
  from_params "Managed identity" "$IDENTITY_TYPE"
else
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
fi

# Bicep @allowed values use PascalCase; shell conditionals use the lowercase form above
IDENTITY_TYPE_BICEP=$([[ "$IDENTITY_TYPE" == "user-assigned" ]] && echo "UserAssigned" || echo "SystemAssigned")

success "Managed identity: ${IDENTITY_TYPE}"

# -----------------------------------------------------------------------------
# Step 8: Resource Naming
# -----------------------------------------------------------------------------

header "Step 8: Resource Naming"

if [[ -n "${PREFIX:-}" ]]; then
  from_params "Resource prefix" "$PREFIX"
else
  prompt PREFIX "Resource prefix (2+ chars, lowercase letters and numbers only, e.g. ar, arpio, myteam)"

  # No hyphens: prefix must be usable as-is in storage account names (most restrictive Azure resource type).
  if ! [[ "$PREFIX" =~ ^[a-z][a-z0-9]+$ ]]; then
    error "Prefix must be 2+ characters, lowercase letters and numbers only (no hyphens). Example: arpio, myteam, staging."
    exit 1
  fi
fi

SUFFIX=$(derive_suffix "$PREFIX" "$SUBSCRIPTION_ID" "$CURRENT_USER_UPN")
[[ -n "$SUFFIX" ]] || { error "Failed to derive resource suffix — check that openssl is installed."; exit 1; }

# Resource names
RG_MAIN="${PREFIX}-rg-${SUFFIX}"
RG_INFRA="${PREFIX}-infra-rg-${SUFFIX}"
CLUSTER_NAME="${PREFIX}-aks-${SUFFIX}"
VNET_NAME="${PREFIX}-vnet-${SUFFIX}"
SUBNET_NAME="${PREFIX}-subnet-${SUFFIX}"
IDENTITY_NAME="${PREFIX}-id-${SUFFIX}"
ENTRA_GROUP_NAME="${PREFIX}-admins-${SUFFIX}"

# Key Vault: max 24 chars, must start with a letter.
# Truncate prefix to 14 chars to leave room for -kv-{6char suffix}.
KV_PREFIX="${PREFIX:0:14}"
KV_PREFIX="${KV_PREFIX%-}"   # strip trailing hyphen if truncation left one
KV_NAME="${KV_PREFIX}-kv-${SUFFIX}"

# ACR: alphanumeric only, no hyphens. Prefix already satisfies this constraint.
# Truncate prefix to 37 chars to leave room for acr + 6-char suffix (max 50 total).
ACR_PREFIX="${PREFIX:0:37}"
ACR_NAME="${ACR_PREFIX}acr${SUFFIX}"

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
echo "  Key Vault:         ${KV_NAME}"
echo "  Container Registry:${ACR_NAME}"
if [[ "$IDENTITY_TYPE" == "user-assigned" ]]; then
  echo "  Managed Identity:  ${IDENTITY_NAME}"
fi
if [[ "$ENTRA_ADMIN_ENABLED" == "true" ]]; then
  echo "  Entra Admin Group: ${ENTRA_GROUP_NAME}"
fi

# -----------------------------------------------------------------------------
# Step 9: Node Pool
# -----------------------------------------------------------------------------

header "Step 9: Node Pool"

if [[ -n "${VM_SKU:-}" ]]; then
  from_params "Node VM SKU" "$VM_SKU"
else
  prompt VM_SKU "Node VM SKU" "Standard_D2s_v3"
fi

if ! [[ "$VM_SKU" =~ ^Standard_[A-Za-z0-9_]+$ ]]; then
  error "VM SKU '${VM_SKU}' does not match expected format (e.g. Standard_D2s_v3)."
  exit 1
fi

if [[ -n "${NODE_COUNT:-}" ]]; then
  from_params "Node count" "$NODE_COUNT"
else
  prompt NODE_COUNT "Node count" "2"

  if ! [[ "$NODE_COUNT" =~ ^[0-9]+$ ]] || (( NODE_COUNT < 1 )); then
    error "Node count must be a positive integer."
    exit 1
  fi
fi

success "Node pool: ${NODE_COUNT}x ${VM_SKU}"

# -----------------------------------------------------------------------------
# Summary + Confirmation
# -----------------------------------------------------------------------------

header "Deployment Summary"

cat <<EOF

  ${BOLD}Subscription:${RESET}       ${SUBSCRIPTION_NAME}
  ${BOLD}Region:${RESET}             ${LOCATION}
  ${BOLD}Configuration:${RESET}      ${NETWORK_CONFIG} — ${NETWORK_CONFIG_DESC}
  ${BOLD}Network plugin:${RESET}     ${NETWORK_PLUGIN}${NETWORK_PLUGIN_MODE:+ (${NETWORK_PLUGIN_MODE})}
EOF
if [[ "$NETWORK_PLUGIN_MODE" == "overlay" ]]; then
  echo -e "  ${BOLD}Network policy:${RESET}     ${NETWORK_POLICY}"
fi
cat <<EOF
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
  ${BOLD}Key Vault:${RESET}          ${KV_NAME}
  ${BOLD}Container Registry:${RESET} ${ACR_NAME}
  ${BOLD}Node pool:${RESET}          ${NODE_COUNT}x ${VM_SKU}
EOF

if [[ "$IDENTITY_TYPE" == "user-assigned" ]]; then
  echo -e "  ${BOLD}Identity:${RESET}           ${IDENTITY_NAME}"
fi
if [[ "$K8S_AUTH" == "entra" ]]; then
  if [[ "$ENTRA_ADMIN_ENABLED" == "true" ]]; then
    echo -e "  ${BOLD}Entra admin group:${RESET}  ${ENTRA_GROUP_NAME}"
  else
    echo -e "  ${BOLD}Entra admin group:${RESET}  none (configure manually after deployment)"
  fi
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
    --query id -o tsv \
    --only-show-errors | tr -d '\r')
  [[ -n "$IDENTITY_RESOURCE_ID" ]] || { error "Failed to retrieve resource ID for identity '${IDENTITY_NAME}'."; exit 1; }

  IDENTITY_PRINCIPAL_ID=$(az identity show \
    --name "$IDENTITY_NAME" \
    --resource-group "$RG_MAIN" \
    --query principalId -o tsv \
    --only-show-errors | tr -d '\r')
  [[ -n "$IDENTITY_PRINCIPAL_ID" ]] || { error "Failed to retrieve principal ID for identity '${IDENTITY_NAME}'."; exit 1; }

  success "Created identity: ${IDENTITY_NAME}"

  info "Assigning Managed Identity Operator to current user..."
  MSYS_NO_PATHCONV=1 az role assignment create \
    --assignee "$CURRENT_USER_ID" \
    --role "Managed Identity Operator" \
    --scope "$IDENTITY_RESOURCE_ID" \
    --output none
  success "Role assigned: Managed Identity Operator → ${CURRENT_USER_UPN}"
fi

# -----------------------------------------------------------------------------
# Entra Admin Group
# -----------------------------------------------------------------------------

ENTRA_GROUP_ID=""

if [[ "$ENTRA_ADMIN_ENABLED" == "true" ]]; then
  header "Creating Entra Admin Group"

  info "Checking for existing Entra group: ${ENTRA_GROUP_NAME}"
  ENTRA_GROUP_ID=$(az ad group list \
    --filter "displayName eq '${ENTRA_GROUP_NAME}'" \
    --query "[0].id" -o tsv 2>/dev/null | tr -d '\r' || true)

  if [[ -n "$ENTRA_GROUP_ID" ]]; then
    warn "Entra group '${ENTRA_GROUP_NAME}' already exists — reusing (${ENTRA_GROUP_ID})."
  else
    info "Creating Entra group: ${ENTRA_GROUP_NAME}"
    ENTRA_GROUP_ID=$(az ad group create \
      --display-name "$ENTRA_GROUP_NAME" \
      --mail-nickname "$ENTRA_GROUP_NAME" \
      --query id -o tsv | tr -d '\r')
    [[ -n "$ENTRA_GROUP_ID" ]] || { error "Failed to create Entra group '${ENTRA_GROUP_NAME}'."; exit 1; }
    success "Created group: ${ENTRA_GROUP_NAME} (${ENTRA_GROUP_ID})"
  fi

  info "Adding current user to group..."
  ALREADY_MEMBER=$(az ad group member check \
    --group "$ENTRA_GROUP_ID" \
    --member-id "$CURRENT_USER_ID" \
    --query value -o tsv 2>/dev/null | tr -d '\r' || echo "false")

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

  SUBNET_ID=$(az network vnet subnet show \
    --resource-group "$RG_INFRA" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --query id -o tsv --only-show-errors 2>/dev/null | tr -d '\r' || true)

  if [[ -n "$SUBNET_ID" ]]; then
    warn "Subnet '${SUBNET_NAME}' already exists — skipping network deployment. Existing network configuration was not changed."
  else
    info "Deploying VNet and subnet into ${RG_INFRA}..."
    SUBNET_ID=$(az deployment group create \
      --resource-group "$RG_INFRA" \
      --template-file "${BICEP_DIR}/modules/network.bicep" \
      --parameters \
          vnetName="$VNET_NAME" \
          subnetName="$SUBNET_NAME" \
          location="$LOCATION" \
      --query "properties.outputs.subnetId.value" -o tsv \
      --only-show-errors | tr -d '\r')
    [[ -n "$SUBNET_ID" ]] || { error "Failed to retrieve subnet ID from network deployment."; exit 1; }
  fi

  # For private-network, the KV private endpoint needs the VNet ID for DNS zone linking.
  VNET_ID=""
  if [[ "$NETWORK_CONFIG" == "private-network" ]]; then
    VNET_ID=$(az network vnet show \
      --name "$VNET_NAME" \
      --resource-group "$RG_INFRA" \
      --query id -o tsv \
      --only-show-errors | tr -d '\r')
    [[ -n "$VNET_ID" ]] || { error "Failed to retrieve VNet ID for '${VNET_NAME}'."; exit 1; }
  fi

  success "VNet and subnet ready: ${VNET_NAME} / ${SUBNET_NAME}"
fi

# -----------------------------------------------------------------------------
# Key Vault soft-delete check
# -----------------------------------------------------------------------------
# Azure retains deleted vaults for 7 days (soft-delete). Recreating a vault
# with the same name in the same region is blocked until it is purged.

DELETED_KV=$(az keyvault list-deleted \
  --query "[?name=='${KV_NAME}'].name" -o tsv 2>/dev/null | tr -d '\r' || true)

if [[ -n "$DELETED_KV" ]]; then
  warn "Key Vault '${KV_NAME}' is in a soft-deleted state."
  warn "It was previously deleted and is within the 7-day retention window."
  echo ""
  if confirm "Purge the deleted vault now to allow redeployment?"; then
    info "Purging deleted Key Vault: ${KV_NAME}..."
    az keyvault purge --name "$KV_NAME" --location "$LOCATION"
    success "Key Vault purged: ${KV_NAME}"
  else
    error "Deployment cannot proceed while a deleted vault with this name exists."
    error "Run manually: az keyvault purge --name \"${KV_NAME}\" --location \"${LOCATION}\""
    exit 1
  fi
fi

# -----------------------------------------------------------------------------
# AKS Cluster
# -----------------------------------------------------------------------------

header "Deploying AKS Cluster"

if [[ "$NETWORK_CONFIG" != "managed-network" ]]; then
  info "Subnet ID: '${SUBNET_ID}'"
  info "Verifying subnet is accessible..."
  az network vnet subnet show \
    --resource-group "$RG_INFRA" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --only-show-errors -o none || {
    error "Subnet not found or not accessible: ${SUBNET_ID}"
    exit 1
  }
  success "Subnet verified."
fi

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
  BICEP_PARAMS+=(clusterIdentityPrincipalId="$IDENTITY_PRINCIPAL_ID")
fi

if [[ "$ENTRA_ADMIN_ENABLED" == "true" ]]; then
  BICEP_PARAMS+=(entraAdminGroupId="$ENTRA_GROUP_ID")
fi

BICEP_PARAMS+=(
  kvName="$KV_NAME"
  acrName="$ACR_NAME"
  deployingUserPrincipalId="$CURRENT_USER_ID"
)

if [[ "$NETWORK_CONFIG" == "private-network" ]]; then
  BICEP_PARAMS+=(vnetId="$VNET_ID")
fi

# Git Bash (MSYS2) auto-converts arguments that look like POSIX paths
# (e.g. /subscriptions/…) to Windows paths, corrupting Azure resource IDs
# passed as --parameters values. MSYS_NO_PATHCONV=1 disables this for the
# az call; cygpath pre-converts the template file path so az can still find it.
_AKS_TEMPLATE="${BICEP_DIR}/main.bicep"
if command -v cygpath &>/dev/null; then
  _AKS_TEMPLATE="$(cygpath -w "$_AKS_TEMPLATE")"
fi

MSYS_NO_PATHCONV=1 az deployment group create \
  --resource-group "$RG_MAIN" \
  --template-file "$_AKS_TEMPLATE" \
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
  info "Entra auth requires kubelogin to convert the kubeconfig before kubectl will work."
  info "Run the following to configure token-based auth using your current az login:"
  echo -e "    kubelogin convert-kubeconfig -l azurecli"
else
  az aks get-credentials \
    --resource-group "$RG_MAIN" \
    --name "$CLUSTER_NAME" \
    --overwrite-existing \
    --admin
  info "kubeconfig uses cluster admin certificate — no Entra dependency."
fi

success "kubeconfig updated. Cluster context: ${CLUSTER_NAME}"

# -----------------------------------------------------------------------------
# Done
# -----------------------------------------------------------------------------

header "Deployment Complete"

cat <<EOF

  ${GREEN}${BOLD}AKS cluster is ready.${RESET}

  ${BOLD}Cluster:${RESET}        ${CLUSTER_NAME}
  ${BOLD}Registry:${RESET}       ${ACR_NAME}.azurecr.io
  ${BOLD}Key Vault:${RESET}      ${KV_NAME}
  ${BOLD}Config:${RESET}         ${NETWORK_CONFIG} — ${NETWORK_CONFIG_DESC}
  ${BOLD}Resource group:${RESET} ${RG_MAIN}
EOF

if [[ "$NETWORK_CONFIG" != "managed-network" ]]; then
  echo -e "  ${BOLD}Infra RG:${RESET}       ${RG_INFRA}"
fi

if [[ "$NETWORK_CONFIG" == "private-network" ]]; then
  echo ""
  warn "This is a private cluster. Install the Arpio private delegate inside the cluster VNet."
  warn "The public Arpio delegate cannot reach private API endpoints."
  warn "Key Vault public access is disabled — manage secrets from within the cluster VNet."
fi

echo ""
info "Test connectivity:  kubectl get nodes"
echo ""
