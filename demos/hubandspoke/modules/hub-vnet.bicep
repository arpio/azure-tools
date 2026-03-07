// ============================================
// Hub VNet Module - Landing Zone Simulation
// ============================================
// Deploys hub VNet with Bastion and VPN Gateway
// Only allows inbound internet connections to Bastion
// Routes all other traffic to VPN Gateway

@description('Resource name prefix')
param resourcePrefix string

@description('Location for all resources')
param location string

@description('Hub VNet address space')
param hubVnetAddressPrefix string = '10.0.0.0/16'

@description('Tags to apply to resources')
param tags object = {}

// ============================================
// Hub Virtual Network with Required Subnets
// ============================================
resource hubVnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: '${resourcePrefix}-hub-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        hubVnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'GatewaySubnet' // Required name for VPN Gateway
        properties: {
          addressPrefix: cidrSubnet(hubVnetAddressPrefix, 26, 0) // 10.0.0.0/26
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'AzureBastionSubnet' // Required name for Bastion
        properties: {
          addressPrefix: cidrSubnet(hubVnetAddressPrefix, 26, 1) // 10.0.0.64/26
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: 'ManagementSubnet'
        properties: {
          addressPrefix: cidrSubnet(hubVnetAddressPrefix, 24, 1) // 10.0.1.0/24
          networkSecurityGroup: {
            id: managementNsg.id
          }
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

// ============================================
// Network Security Group for Management Subnet
// ============================================
resource managementNsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: '${resourcePrefix}-hub-management-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowBastionInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: cidrSubnet(hubVnetAddressPrefix, 26, 1) // Bastion subnet
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Allow all traffic from Bastion'
        }
      }
      {
        name: 'DenyAllOtherInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Deny all other inbound traffic'
        }
      }
    ]
  }
}

// ============================================
// Azure Bastion - Only Internet Entry Point
// ============================================
resource bastionPublicIp 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: '${resourcePrefix}-bastion-pip'
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

resource bastion 'Microsoft.Network/bastionHosts@2023-05-01' = {
  name: '${resourcePrefix}-bastion'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    enableTunneling: true
    enableFileCopy: true
    enableIpConnect: true
    ipConfigurations: [
      {
        name: 'bastionIpConfig'
        properties: {
          subnet: {
            id: '${hubVnet.id}/subnets/AzureBastionSubnet'
          }
          publicIPAddress: {
            id: bastionPublicIp.id
          }
        }
      }
    ]
  }
}

// ============================================
// VPN Gateway
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

// VPN Gateway - WARNING: Takes 30-45 minutes to deploy
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
// Route Table for Spoke VNets
// Routes all internet traffic to VPN Gateway
// ============================================
resource spokeRouteTable 'Microsoft.Network/routeTables@2023-05-01' = {
  name: '${resourcePrefix}-spoke-rt'
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: false
    routes: [
      {
        name: 'InternetToVpnGateway'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualNetworkGateway'
        }
      }
    ]
  }
}

// ============================================
// Outputs
// ============================================
output hubVnetId string = hubVnet.id
output hubVnetName string = hubVnet.name
output hubVnetAddressPrefix string = hubVnetAddressPrefix
output gatewaySubnetId string = '${hubVnet.id}/subnets/GatewaySubnet'
output bastionSubnetId string = '${hubVnet.id}/subnets/AzureBastionSubnet'
output bastionSubnetAddressPrefix string = cidrSubnet(hubVnetAddressPrefix, 26, 1)
output managementSubnetId string = '${hubVnet.id}/subnets/ManagementSubnet'
output bastionId string = bastion.id
output bastionPublicIp string = bastionPublicIp.properties.ipAddress
output vpnGatewayId string = vpnGateway.id
output vpnGatewayPublicIp string = vpnGatewayPublicIp.properties.ipAddress
output spokeRouteTableId string = spokeRouteTable.id
