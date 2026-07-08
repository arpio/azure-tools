// =============================================================================
// private-network configuration
// =============================================================================
// Script-created VNet, private API endpoint, private Arpio delegate required.
// Supports Azure CNI Overlay or Kubenet.
// See README.md in this directory for usage instructions.
// =============================================================================

using '../main.bicep'

// ---------------------------------------------------------------------------
// Required — fill in before deploying directly
// ---------------------------------------------------------------------------

param clusterName              = 'MY_CLUSTER_NAME'
param subnetId                 = '/subscriptions/SUB_ID/resourceGroups/RG/providers/Microsoft.Network/virtualNetworks/VNET/subnets/SUBNET'
param vnetId                   = '/subscriptions/SUB_ID/resourceGroups/RG/providers/Microsoft.Network/virtualNetworks/VNET'
param kvName                   = 'MY_KV_NAME'
param acrName                  = 'myacrname'
param appIdentityName          = 'MY_APP_IDENTITY'
param deployingUserPrincipalId = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'

// ---------------------------------------------------------------------------
// Network (pre-set for private-network)
// ---------------------------------------------------------------------------

param networkConfig         = 'private-network'
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

// ---------------------------------------------------------------------------
// Database (optional)
// ---------------------------------------------------------------------------
// Uncomment and fill in to provision a database alongside the cluster.
// databaseType defaults to 'none' — leave everything below commented to skip.
// The database automatically gets a private endpoint on the subnetId/vnetId
// above — no extra networking params needed.

// param databaseType = 'sql'   // sql | postgresql | cosmosdb
// param databaseName = 'appdb'

// --- sql only: Azure SQL accepts a single AAD admin principal, so pre-create
// an Entra group containing whichever users/identities need admin access and
// pass its ID/name here (deploy-cluster.sh creates this group for you).
// param sqlServerName    = 'MY_SQL_SERVER'
// param dbAdminGroupId   = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
// param dbAdminGroupName = 'my-db-admins'

// --- postgresql only: both the deploying user and app workload identity are
// granted admin directly.
// param postgresServerName = 'MY_PG_SERVER'
// param deployingUserUpn   = 'user@example.com'

// --- cosmosdb only:
// param cosmosAccountName = 'mycosmosaccount'
