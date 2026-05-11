// =============================================================================
// managed-network configuration parameter defaults
// =============================================================================
// Azure-managed VNet, API server VNet integration, public API, public delegate.
//
// These are reference defaults. deploy-cluster.sh populates parameters
// at runtime based on user input. Edit this file to override defaults
// for your environment.
// =============================================================================

using '../main.bicep'

param networkConfig         = 'managed-network'
param networkPlugin         = 'azure'
param networkPluginMode     = 'overlay'
param networkPolicy         = 'azure'          // or 'cilium'
param k8sAuth               = 'entra'
param identityType          = 'SystemAssigned'
param nodeVmSku             = 'Standard_D2s_v3'
param nodeCount             = 2

// Populated at runtime by deploy-cluster.sh:
// param clusterName
// param location
// param entraAdminGroupId
// param kvName
// param deployingUserPrincipalId
