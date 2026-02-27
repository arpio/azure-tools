// ============================================
// App 2 VNet Module
// ============================================
// Deploys App 2 VNet with:
// - Single subnet with Windows VM
// - User Assigned Identity
// - Application Security Group
// - All traffic routed through Hub VNet

@description('Resource name prefix')
param resourcePrefix string

@description('Location for all resources')
param location string

@description('App 2 VNet address space')
param app2VnetAddressPrefix string = '10.2.0.0/16'

@description('Hub VNet Bastion subnet address prefix for NSG rules')
param bastionSubnetAddressPrefix string

@description('Route table ID from Hub VNet')
param spokeRouteTableId string

@description('Admin username for VM')
param adminUsername string

@description('Admin password for VM')
@secure()
param adminPassword string

@description('VM Size')
param vmSize string = 'Standard_D2ads_v7'

@description('Tags to apply to resources')
param tags object = {}

// ============================================
// User Assigned Managed Identity
// ============================================
resource userIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${resourcePrefix}-app2-identity'
  location: location
  tags: tags
}

// ============================================
// Application Security Group
// ============================================
resource appAsg 'Microsoft.Network/applicationSecurityGroups@2023-05-01' = {
  name: '${resourcePrefix}-app2-asg'
  location: location
  tags: tags
}

// ============================================
// Network Security Group
// All traffic routed through Hub VNet
// ============================================
resource subnet1Nsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: '${resourcePrefix}-app2-subnet1-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowBastionRDP'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnetAddressPrefix
          sourcePortRange: '*'
          destinationApplicationSecurityGroups: [
            {
              id: appAsg.id
            }
          ]
          destinationPortRange: '3389'
          description: 'Allow RDP from Bastion'
        }
      }
      {
        name: 'AllowHubVnet'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationApplicationSecurityGroups: [
            {
              id: appAsg.id
            }
          ]
          destinationPortRange: '*'
          description: 'Allow traffic from Hub VNet (via peering)'
        }
      }
      {
        name: 'DenyInternetInbound'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationApplicationSecurityGroups: [
            {
              id: appAsg.id
            }
          ]
          destinationPortRange: '*'
          description: 'Block all internet inbound traffic'
        }
      }
    ]
  }
}

// ============================================
// App 2 Virtual Network
// ============================================
resource app2Vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: '${resourcePrefix}-app2-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        app2VnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'AppSubnet'
        properties: {
          addressPrefix: cidrSubnet(app2VnetAddressPrefix, 24, 0) // 10.2.0.0/24
          networkSecurityGroup: {
            id: subnet1Nsg.id
          }
          routeTable: {
            id: spokeRouteTableId
          }
        }
      }
    ]
  }
}

// ============================================
// Windows VM with User Assigned Identity
// ============================================
resource vmNic 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: '${resourcePrefix}-app2-vm-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${app2Vnet.id}/subnets/AppSubnet'
          }
          applicationSecurityGroups: [
            {
              id: appAsg.id
            }
          ]
        }
      }
    ]
  }
}

resource windowsVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: '${resourcePrefix}-app2-vm'
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${userIdentity.id}': {}
    }
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-azure-edition'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
    }
    osProfile: {
      computerName: '${resourcePrefix}app2'
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        enableAutomaticUpdates: true
        provisionVMAgent: true
        patchSettings: {
          patchMode: 'AutomaticByOS'
          assessmentMode: 'ImageDefault'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: vmNic.id
        }
      ]
    }
  }
}

// ============================================
// Outputs
// ============================================
output app2VnetId string = app2Vnet.id
output app2VnetName string = app2Vnet.name
output appSubnetId string = '${app2Vnet.id}/subnets/AppSubnet'
output vmId string = windowsVm.id
output vmName string = windowsVm.name
output vmPrivateIp string = vmNic.properties.ipConfigurations[0].properties.privateIPAddress
output userIdentityId string = userIdentity.id
output userIdentityPrincipalId string = userIdentity.properties.principalId
output userIdentityClientId string = userIdentity.properties.clientId
output appAsgId string = appAsg.id
