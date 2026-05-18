// =============================================================================
// Arpio AKS Cluster - Main Bicep Template
// =============================================================================
// Deploys an AKS cluster for one of three network configurations:
//   managed-network  - Azure-managed VNet, API server VNet integration
//   custom-network   - BYO VNet, public API
//   private-network  - BYO VNet, private API
// =============================================================================

@description('Name of the AKS cluster.')
param clusterName string

@description('Azure region for all resources.')
param location string = resourceGroup().location

@description('Network configuration: managed-network | custom-network | private-network')
@allowed(['managed-network', 'custom-network', 'private-network'])
param networkConfig string

@description('Kubernetes network plugin: azure | kubenet')
@allowed(['azure', 'kubenet'])
param networkPlugin string = 'azure'

@description('Network plugin mode. Set to overlay for Azure CNI Overlay. Leave empty for kubenet.')
param networkPluginMode string = ''

@description('Network policy engine: azure | cilium. Cilium requires Azure CNI Overlay.')
@allowed(['azure', 'cilium'])
param networkPolicy string = 'azure'

@description('Subnet resource ID for the AKS node pool. Required when networkConfig is custom-network or private-network. Leave empty for managed-network.')
param subnetId string = ''

@description('Kubernetes authentication mode: entra | classic')
@allowed(['entra', 'classic'])
param k8sAuth string = 'entra'

@description('Entra admin group object ID. Required when k8sAuth is entra.')
param entraAdminGroupId string = ''

@description('Managed identity type: SystemAssigned | UserAssigned')
@allowed(['SystemAssigned', 'UserAssigned'])
param identityType string = 'SystemAssigned'

@description('Resource ID of a user-assigned managed identity. Required when identityType is UserAssigned.')
param userAssignedIdentityId string = ''

@description('VM SKU for the default node pool.')
param nodeVmSku string = 'Standard_D2s_v3'

@description('Number of nodes in the default node pool.')
@minValue(1)
param nodeCount int = 2

@description('Name of the Key Vault. Max 24 chars, must start with a letter.')
param kvName string

@description('Object ID of the deploying user. Granted Key Vault Administrator.')
param deployingUserPrincipalId string

@description('Principal ID of the cluster managed identity. Pass when identityType is UserAssigned (resolved before cluster creation). Leave empty for SystemAssigned — derived from the cluster output post-creation.')
param clusterIdentityPrincipalId string = ''

@description('VNet resource ID for Key Vault private endpoint DNS zone link. Required when networkConfig is private-network.')
param vnetId string = ''

@description('Name of the Azure Container Registry. Alphanumeric only, 5–50 chars.')
param acrName string

@description('Name of the user-assigned managed identity for application workloads (AKS Workload Identity).')
param appIdentityName string

// ---------------------------------------------------------------------------
// Derived values
// ---------------------------------------------------------------------------

var isPrivate     = networkConfig == 'private-network'
var isManagedNet  = networkConfig == 'managed-network'
var enableEntra   = k8sAuth == 'entra'

// For UserAssigned: caller passes the identity's principal ID (known before cluster creation).
// For SystemAssigned: derive from cluster output after creation.
var kvPrincipalId = empty(clusterIdentityPrincipalId)
  ? cluster.outputs.clusterPrincipalId
  : clusterIdentityPrincipalId

// Guard: custom-network and private-network require a subnetId. Passing an invalid
// sentinel (not a resource ID) causes ARM to reject the deployment at validation
// time rather than silently creating a cluster without a subnet.
var effectiveSubnetId = (!isManagedNet && empty(subnetId))
  ? 'ERROR_subnetId_required_for_${networkConfig}'
  : subnetId

// ---------------------------------------------------------------------------
// Cluster module
// ---------------------------------------------------------------------------

module cluster './modules/cluster.bicep' = {
  name: 'aks-cluster'
  params: {
    clusterName:            clusterName
    location:               location
    networkPlugin:          networkPlugin
    networkPluginMode:      networkPluginMode
    networkPolicy:          networkPolicy
    subnetId:               effectiveSubnetId
    isPrivate:              isPrivate
    enableEntraAuth:        enableEntra
    entraAdminGroupId:      entraAdminGroupId
    identityType:           identityType
    userAssignedIdentityId: userAssignedIdentityId
    nodeVmSku:              nodeVmSku
    nodeCount:              nodeCount
  }
}

// ---------------------------------------------------------------------------
// Key Vault module
// ---------------------------------------------------------------------------

module keyvault './modules/keyvault.bicep' = {
  name: 'key-vault'
  params: {
    kvName:                   kvName
    location:                 location
    clusterPrincipalId:       kvPrincipalId
    deployingUserPrincipalId: deployingUserPrincipalId
    isPrivateNetwork:         isPrivate
    subnetId:                 effectiveSubnetId
    vnetId:                   vnetId
  }
}

// ---------------------------------------------------------------------------
// Application workload identity
// ---------------------------------------------------------------------------
// A dedicated user-assigned identity for app pods. Workload Identity federates
// K8s service account tokens against this identity's OIDC trust so pods can
// authenticate to Azure services (e.g. PostgreSQL) without embedded credentials.
// The federated credential is created separately once the namespace and service
// account name are known.

module appIdentity './modules/identity.bicep' = {
  name: 'app-identity'
  params: {
    identityName: appIdentityName
    location:     location
  }
}

// ---------------------------------------------------------------------------
// Container Registry module
// ---------------------------------------------------------------------------

module acr './modules/acr.bicep' = {
  name: 'container-registry'
  params: {
    acrName:                  acrName
    location:                 location
    isPrivateNetwork:         isPrivate
    subnetId:                 effectiveSubnetId
    vnetId:                   vnetId
    deployingUserPrincipalId: deployingUserPrincipalId
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output clusterName            string = cluster.outputs.clusterName
output clusterFqdn            string = cluster.outputs.clusterFqdn
output nodeResourceGroup      string = cluster.outputs.nodeResourceGroup
output kvName                 string = keyvault.outputs.kvName
output kvUri                  string = keyvault.outputs.kvUri
output acrName                string = acr.outputs.acrName
output acrLoginServer         string = acr.outputs.acrLoginServer
output oidcIssuerUrl          string = cluster.outputs.oidcIssuerUrl
output appIdentityName        string = appIdentity.outputs.identityName
output appIdentityClientId    string = appIdentity.outputs.identityClientId
output appIdentityPrincipalId string = appIdentity.outputs.identityPrincipalId
