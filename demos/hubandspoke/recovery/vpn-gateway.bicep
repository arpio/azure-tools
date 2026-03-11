// ============================================
// Recovery: VPN Gateway for Hub VNet
// ============================================
// Pre-provisions a VPN Gateway in the recovery environment's hub VNet.
// The hub VNet must already exist (created by Arpio during recovery).
//
// Why: Spoke VNet peerings use useRemoteGateways: true, which requires
// a gateway in the hub VNet. Without it, peerings fail. The gateway
// takes 30-45 minutes to deploy, so it should be created before failover.
//
// Usage:
//   az deployment group create \
//     --resource-group <prefix>-hub-rg \
//     --template-file recovery/vpn-gateway.bicep \
//     --parameters resourcePrefix=<prefix> location=<region>

@description('Resource name prefix (must match the main deployment)')
param resourcePrefix string

@description('Location for all resources (recovery region)')
param location string

@description('Tags to apply to all resources')
param tags object = {
  Environment: 'Demo'
  ManagedBy: 'Bicep'
  Architecture: 'Hub-Spoke'
}

// ============================================
// Reference the existing hub VNet
// (already recovered by Arpio — we only add the gateway)
// ============================================
resource hubVnet 'Microsoft.Network/virtualNetworks@2023-05-01' existing = {
  name: '${resourcePrefix}-hub-vnet'
}

// ============================================
// Public IP for VPN Gateway
// ============================================
resource vpnGatewayPublicIp 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: '${resourcePrefix}-vpn-pip'
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
  name: '${resourcePrefix}-vpn-gateway'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'vpnGatewayIpConfig'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${hubVnet.id}/subnets/GatewaySubnet'
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
// Outputs
// ============================================
output vpnGatewayId string = vpnGateway.id
output vpnGatewayPublicIp string = vpnGatewayPublicIp.properties.ipAddress
