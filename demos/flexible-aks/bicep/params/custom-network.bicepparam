// =============================================================================
// custom-network configuration parameter defaults
// =============================================================================
// Customer-provided VNet (script creates it), public API, public delegate.
// Supports Azure CNI Overlay or Kubenet.
// =============================================================================

using '../main.bicep'

param networkConfig         = 'custom-network'
param networkPlugin         = 'azure'        // or 'kubenet'
param networkPluginMode     = 'overlay'      // empty string if kubenet
param networkPolicy         = 'azure'        // or 'cilium' (Azure CNI Overlay only)
param k8sAuth               = 'entra'
param identityType          = 'SystemAssigned'
param nodeVmSku             = 'Standard_D2s_v3'
param nodeCount             = 2

// Populated at runtime by deploy-cluster.sh:
// param clusterName
// param location
// param subnetId
// param entraAdminGroupId
// param userAssignedIdentityId
// param kvName
// param deployingUserPrincipalId
// param clusterIdentityPrincipalId  (UserAssigned only)
