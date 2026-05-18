// =============================================================================
// custom-network configuration
// =============================================================================
// Script-created VNet, public API endpoint, public Arpio delegate.
// Supports Azure CNI Overlay or Kubenet.
// See README.md in this directory for usage instructions.
// =============================================================================

using '../main.bicep'

// ---------------------------------------------------------------------------
// Required — fill in before deploying directly
// ---------------------------------------------------------------------------

param clusterName              = 'MY_CLUSTER_NAME'
param subnetId                 = '/subscriptions/SUB_ID/resourceGroups/RG/providers/Microsoft.Network/virtualNetworks/VNET/subnets/SUBNET'
param kvName                   = 'MY_KV_NAME'
param acrName                  = 'myacrname'
param appIdentityName          = 'MY_APP_IDENTITY'
param deployingUserPrincipalId = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

// ---------------------------------------------------------------------------
// Network (pre-set for custom-network)
// ---------------------------------------------------------------------------

param networkConfig         = 'custom-network'
param networkPlugin         = 'azure'        // or 'kubenet'
param networkPluginMode     = 'overlay'      // empty string if kubenet
param networkPolicy         = 'azure'        // or 'cilium' (Azure CNI Overlay only)

// ---------------------------------------------------------------------------
// Auth and identity
// ---------------------------------------------------------------------------

param k8sAuth               = 'entra'
// param entraAdminGroupId          = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
// param userAssignedIdentityId     = '/subscriptions/.../userAssignedIdentities/NAME'  // UserAssigned only
// param clusterIdentityPrincipalId = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'            // UserAssigned only
param identityType          = 'SystemAssigned'

// ---------------------------------------------------------------------------
// Node pool
// ---------------------------------------------------------------------------

param nodeVmSku             = 'Standard_D2s_v3'
param nodeCount             = 2
