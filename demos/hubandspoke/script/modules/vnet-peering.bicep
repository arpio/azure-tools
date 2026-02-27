// ============================================
// VNet Peering Module
// ============================================
// Creates bidirectional peering between two virtual networks

@description('Name of the local virtual network')
param localVnetName string

@description('Name of the remote virtual network (for naming)')
param remoteVnetName string

@description('Resource ID of the remote virtual network')
param remoteVnetId string

@description('Allow traffic forwarded from the remote network')
param allowForwardedTraffic bool = true

@description('Allow gateway transit (hub only)')
param allowGatewayTransit bool = false

@description('Use remote gateways (spokes only)')
param useRemoteGateways bool = false

resource localVnet 'Microsoft.Network/virtualNetworks@2023-05-01' existing = {
  name: localVnetName
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-05-01' = {
  parent: localVnet
  name: '${localVnetName}-to-${remoteVnetName}'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: allowForwardedTraffic
    allowGatewayTransit: allowGatewayTransit
    useRemoteGateways: useRemoteGateways
    remoteVirtualNetwork: {
      id: remoteVnetId
    }
  }
}

output peeringId string = peering.id
output peeringName string = peering.name
