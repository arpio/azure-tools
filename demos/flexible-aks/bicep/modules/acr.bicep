// =============================================================================
// Container Registry Module
// =============================================================================
// Creates an Azure Container Registry with RBAC authorization. Grants:
//   AcrPush → deploying user
//   AcrPull → cluster kubelet identity (the identity that pulls images on nodes)
//
// For private-network: uses Premium SKU, disables public access, and provisions
// a private endpoint with private DNS zone integration into the cluster VNet.
// =============================================================================

@description('Name of the container registry. Alphanumeric only, 5–50 chars.')
param acrName string

@description('Azure region.')
param location string = resourceGroup().location

@description('Disable public access and create a private endpoint.')
param isPrivateNetwork bool = false

@description('Subnet resource ID for the private endpoint. Required when isPrivateNetwork is true.')
param subnetId string = ''

@description('VNet resource ID for the private DNS zone VNet link. Required when isPrivateNetwork is true.')
param vnetId string = ''

@description('Object ID of the deploying user. Granted AcrPush.')
param deployingUserPrincipalId string

@description('Object ID of the cluster kubelet managed identity. Granted AcrPull.')
param kubeletIdentityObjectId string

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name:     acrName
  location: location
  sku: {
    // Premium required for private endpoints; Standard sufficient otherwise.
    name: isPrivateNetwork ? 'Premium' : 'Standard'
  }
  properties: {
    adminUserEnabled:    false
    publicNetworkAccess: isPrivateNetwork ? 'Disabled' : 'Enabled'
  }
}

// ---------------------------------------------------------------------------
// RBAC: deploying user → AcrPush
// ---------------------------------------------------------------------------

resource acrPushAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name:  guid(acr.id, deployingUserPrincipalId, 'acr-push')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '8311e382-0749-4cb8-b61a-304f252e45ec' // AcrPush
    )
    principalId:   deployingUserPrincipalId
    principalType: 'User'
  }
}

// ---------------------------------------------------------------------------
// RBAC: kubelet identity → AcrPull
// ---------------------------------------------------------------------------

resource acrPullAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name:  guid(acr.id, kubeletIdentityObjectId, 'acr-pull')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '7f951dda-4ed3-4680-a7ca-43fe172d538d' // AcrPull
    )
    principalId:   kubeletIdentityObjectId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Private endpoint and DNS (private-network only)
// ---------------------------------------------------------------------------

resource acrPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (isPrivateNetwork) {
  name:     '${acrName}-pe'
  location: location
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: '${acrName}-pe-conn'
        properties: {
          privateLinkServiceId: acr.id
          groupIds:             ['registry']
        }
      }
    ]
  }
}

resource acrDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (isPrivateNetwork) {
  name:     'privatelink.azurecr.io'
  location: 'global'
}

resource acrDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (isPrivateNetwork) {
  parent:   acrDnsZone
  name:     '${acrName}-vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}

resource acrDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (isPrivateNetwork) {
  parent: acrPrivateEndpoint
  name:   'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-azurecr-io'
        properties: {
          privateDnsZoneId: acrDnsZone.id
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output acrName        string = acr.name
output acrLoginServer string = acr.properties.loginServer
