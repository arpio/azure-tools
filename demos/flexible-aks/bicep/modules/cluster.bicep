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

// Two fully-typed array literals so the ARM property compiles to a single
// top-level expression rather than a literal array with an expression element.
// vnetSubnetID is only present (and never null) when a subnet ID is provided.
var agentPoolProfiles = !empty(subnetId) ? [
  {
    name:         'system'
    mode:         'System'
    count:        nodeCount
    vmSize:       nodeVmSku
    osType:       'Linux'
    osDiskType:   'Managed'
    vnetSubnetID: subnetId
  }
] : [
  {
    name:       'system'
    mode:       'System'
    count:      nodeCount
    vmSize:     nodeVmSku
    osType:     'Linux'
    osDiskType: 'Managed'
  }
]

// ---------------------------------------------------------------------------
// Network profile
// ---------------------------------------------------------------------------

// Service and pod CIDRs are set explicitly to avoid overlap with the VNet
// address space (10.0.0.0/8). AKS rejects configurations where the default
// service CIDR (10.0.0.0/16) or pod CIDR (10.244.0.0/16) falls inside the VNet.
var networkProfile = networkPluginMode == 'overlay' ? {
  networkPlugin:     networkPlugin
  networkPluginMode: 'overlay'
  networkPolicy:     networkPolicy
  networkDataplane:  networkPolicy == 'cilium' ? 'cilium' : 'azure'
  podCidr:           '192.168.0.0/16'
  serviceCidr:       '172.16.0.0/16'
  dnsServiceIP:      '172.16.0.10'
} : {
  // networkPolicy intentionally omitted for kubenet — Azure Network Policy and
  // Cilium both require Azure CNI Overlay. Kubenet uses its own UDR-based routing.
  networkPlugin: networkPlugin
  podCidr:       '192.168.0.0/16'
  serviceCidr:   '172.16.0.0/16'
  dnsServiceIP:  '172.16.0.10'
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
    agentPoolProfiles: agentPoolProfiles
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

    // Required for AKS Workload Identity — pods exchange K8s service account
    // tokens for Azure managed identity tokens via the OIDC issuer endpoint.
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output clusterName             string = aksCluster.name
output clusterFqdn             string = aksCluster.properties.fqdn
output nodeResourceGroup       string = aksCluster.properties.nodeResourceGroup
output kubeletIdentityObjectId string = aksCluster.properties.identityProfile.kubeletidentity.objectId
// Empty string for UserAssigned clusters; main.bicep uses clusterIdentityPrincipalId param instead.
output clusterPrincipalId      string = aksCluster.identity.principalId
output oidcIssuerUrl           string = aksCluster.properties.oidcIssuerProfile.issuerURL
