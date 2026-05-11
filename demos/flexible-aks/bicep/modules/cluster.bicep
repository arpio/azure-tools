// =============================================================================
// AKS Cluster Module
// =============================================================================
// Handles all three network configurations via parameters.
// Networking resources (VNet/subnet) are provisioned separately via network.bicep.
// Identity resources are provisioned separately via identity.bicep.
// =============================================================================

@description('Name of the AKS cluster.')
param clusterName string

@description('Azure region.')
param location string = resourceGroup().location

@description('Kubernetes network plugin: azure | kubenet')
@allowed(['azure', 'kubenet'])
param networkPlugin string = 'azure'

@description('Network plugin mode. Set to overlay for Azure CNI Overlay.')
param networkPluginMode string = ''

@description('Network policy engine: azure | cilium. Cilium requires Azure CNI Overlay and also sets networkDataplane to cilium.')
@allowed(['azure', 'cilium'])
param networkPolicy string = 'azure'

@description('Subnet resource ID for node pool. Empty for managed-network.')
param subnetId string = ''

@description('Whether this is a private cluster (no public API endpoint).')
param isPrivate bool = false

@description('Enable API server VNet integration (managed-network only).')
param enableApiServerVnetInt bool = false

@description('Enable Entra ID authentication.')
param enableEntraAuth bool = true

@description('Entra admin group object ID.')
param entraAdminGroupId string = ''

@description('Managed identity type: SystemAssigned | UserAssigned')
@allowed(['SystemAssigned', 'UserAssigned'])
param identityType string = 'SystemAssigned'

@description('Resource ID of a user-assigned managed identity.')
param userAssignedIdentityId string = ''

@description('VM SKU for the system node pool.')
param nodeVmSku string = 'Standard_D2s_v3'

@description('Number of nodes in the system node pool.')
@minValue(1)
param nodeCount int = 2

// ---------------------------------------------------------------------------
// Identity object — conditional based on type
// ---------------------------------------------------------------------------

var identityObject = identityType == 'UserAssigned' ? {
  type: 'UserAssigned'
  userAssignedIdentities: {
    '${userAssignedIdentityId}': {}
  }
} : {
  type: 'SystemAssigned'
}

// ---------------------------------------------------------------------------
// Agent pool profile
// ---------------------------------------------------------------------------

var agentPoolProfile = {
  name:   'system'
  mode:   'System'
  count:   nodeCount
  vmSize:  nodeVmSku
  osType: 'Linux'
  osDiskType: 'Managed'
  // Attach to customer subnet when provided
  vnetSubnetID: !empty(subnetId) ? subnetId : null
}

// ---------------------------------------------------------------------------
// Network profile
// ---------------------------------------------------------------------------

var networkProfile = networkPluginMode == 'overlay' ? {
  networkPlugin:     networkPlugin
  networkPluginMode: 'overlay'
  networkPolicy:     networkPolicy
  networkDataplane:  networkPolicy == 'cilium' ? 'cilium' : 'azure'
} : {
  // networkPolicy intentionally omitted for kubenet — Azure Network Policy and
  // Cilium both require Azure CNI Overlay. Kubenet uses its own UDR-based routing.
  networkPlugin: networkPlugin
}

// ---------------------------------------------------------------------------
// API server access profile
// ---------------------------------------------------------------------------

var apiServerAccessProfile = {
  enablePrivateCluster: isPrivate
  // Public access is enabled by default when isPrivate is false.
  // When isPrivate is true, the API server is only accessible within the VNet.
}

// ---------------------------------------------------------------------------
// Entra auth profile
// ---------------------------------------------------------------------------

var aadProfile = enableEntraAuth ? {
  managed:             true
  enableAzureRBAC:     true
  adminGroupObjectIDs: !empty(entraAdminGroupId) ? [entraAdminGroupId] : []
} : null

// ---------------------------------------------------------------------------
// AKS Cluster
// ---------------------------------------------------------------------------

resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-09-01' = {
  name:     clusterName
  location: location
  identity: identityObject

  properties: {
    dnsPrefix:   clusterName
    networkProfile: networkProfile
    agentPoolProfiles: [agentPoolProfile]
    // Entra auth (null = disabled, object = enabled)
    aadProfile: aadProfile

    // API server VNet integration (managed-network config only)
    apiServerAccessProfile: enableApiServerVnetInt ? {
      enablePrivateCluster:        false
      enableVnetIntegration:       true
      subnetId:                    subnetId
    } : apiServerAccessProfile

    // Disable local accounts when using Entra (security best practice)
    disableLocalAccounts: enableEntraAuth
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output clusterName       string = aksCluster.name
output clusterFqdn       string = aksCluster.properties.fqdn
output nodeResourceGroup string = aksCluster.properties.nodeResourceGroup
output kubeletIdentityObjectId string = aksCluster.properties.identityProfile.kubeletidentity.objectId
