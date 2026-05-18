// =============================================================================
// managed-network configuration
// =============================================================================
// Azure-managed VNet, public API endpoint, public Arpio delegate.
// See README.md in this directory for usage instructions.
// =============================================================================

using '../main.bicep'

// ---------------------------------------------------------------------------
// Required — fill in before deploying directly
// ---------------------------------------------------------------------------

param clusterName              = 'MY_CLUSTER_NAME'
param kvName                   = 'MY_KV_NAME'
param acrName                  = 'myacrname'
param appIdentityName          = 'MY_APP_IDENTITY'
param deployingUserPrincipalId = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

// ---------------------------------------------------------------------------
// Network (pre-set for managed-network)
// ---------------------------------------------------------------------------

param networkConfig         = 'managed-network'
param networkPlugin         = 'azure'
param networkPluginMode     = 'overlay'
param networkPolicy         = 'azure'          // or 'cilium'

// ---------------------------------------------------------------------------
// Auth and identity
// ---------------------------------------------------------------------------

param k8sAuth               = 'entra'
// param entraAdminGroupId  = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
param identityType          = 'SystemAssigned'

// ---------------------------------------------------------------------------
// Node pool
// ---------------------------------------------------------------------------

param nodeVmSku             = 'Standard_D2s_v3'
param nodeCount             = 2
