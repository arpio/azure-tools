// ============================================
// Virtual Network Gateway Module
// ============================================
// Deploys a VNet with a VPN Gateway and hub-side VNet peerings
// WARNING: VPN Gateway takes 30-45 minutes to deploy

@description('Azure region for all resources')
param location string

@description('Resource group name (used for naming and tags)')
param resourceGroupName string

@description('Name for the virtual network')
param vnetName string

@description('Address prefix for the virtual network (e.g., 10.0.0.0/16)')
param vnetAddressPrefix string

@description('Address prefix for the GatewaySubnet (e.g., 10.0.0.0/27 — must fall within vnetAddressPrefix)')
param gatewaySubnetPrefix string

@description('Name for the public IP address resource')
param publicIpName string

@description('Array of remote VNet resource IDs to peer with (hub-side: gateway transit enabled)')
param peeringVnetIds array = []

@description('Tags to apply to all resources')
param tags object = {
  resourceGroup: resourceGroupName
  managedBy: 'bicep'
}

// ============================================
// Virtual Network with GatewaySubnet
// ============================================
resource vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: vnetName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'GatewaySubnet' // Required name — Azure enforces this for VPN Gateways
        properties: {
          addressPrefix: gatewaySubnetPrefix
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// ============================================
// Public IP Address for VPN Gateway
// ============================================
resource vpnGatewayPublicIp 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: publicIpName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

// ============================================
// VPN Gateway
// WARNING: Takes 30-45 minutes to deploy
// ============================================
resource vpnGateway 'Microsoft.Network/virtualNetworkGateways@2023-05-01' = {
  name: '${vnetName}-vpn-gateway'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'vpnGatewayIpConfig'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${vnet.id}/subnets/GatewaySubnet'
          }
          publicIPAddress: {
            id: vpnGatewayPublicIp.id
          }
        }
      }
    ]
    sku: {
      name: 'VpnGw1'
      tier: 'VpnGw1'
    }
    gatewayType: 'Vpn'
    vpnType: 'RouteBased'
    enableBgp: false
  }
}

// ============================================
// VNet Peerings — Hub Side
// allowGatewayTransit: true  → this gateway is shared with peers
// useRemoteGateways: false   → this VNet owns the gateway
// Peerings depend on the gateway being fully deployed first
// ============================================
resource peerings 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-05-01' = [for peeringVnetId in peeringVnetIds: {
  parent: vnet
  name: '${vnetName}-to-${last(split(peeringVnetId, '/'))}'
  properties: {
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: true
    useRemoteGateways: false
    remoteVirtualNetwork: {
      id: peeringVnetId
    }
  }
  dependsOn: [vpnGateway]
}]

// ============================================
// Outputs
// ============================================
output vnetId string = vnet.id
output vnetName string = vnet.name
output gatewaySubnetId string = '${vnet.id}/subnets/GatewaySubnet'
output vpnGatewayId string = vpnGateway.id
output vpnGatewayName string = vpnGateway.name
output vpnGatewayPublicIpAddress string = vpnGatewayPublicIp.properties.ipAddress
output peeringIds array = [for (id, i) in peeringVnetIds: peerings[i].id]
