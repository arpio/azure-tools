// ============================================
// App 1 VNet Module
// ============================================
// Deploys App 1 VNet with:
// - Subnet 1: Public Load Balancer + Linux VMSS (ports 80/443)
// - Subnet 2: Linux Database VM (only accessible from Subnet 1 and Bastion)
// All outbound traffic routed to VPN Gateway in Hub

@description('Resource name prefix')
param resourcePrefix string

@description('Location for all resources')
param location string

@description('App 1 VNet address space')
param app1VnetAddressPrefix string = '10.1.0.0/16'

@description('Hub VNet Bastion subnet address prefix for NSG rules')
param bastionSubnetAddressPrefix string

@description('Route table ID from Hub VNet')
param spokeRouteTableId string

@description('Admin username for VMs')
param adminUsername string

@description('Admin password for VMs')
@secure()
param adminPassword string

@description('VMSS instance count')
param vmssInstanceCount int = 2

@description('VM size for all linux/ARM VMs')
param vmSizeLinux string = 'Standard_B2PS_v2'

@description('Tags to apply to resources')
param tags object = {}

// ============================================
// Application Security Group
// ============================================
resource webAsg 'Microsoft.Network/applicationSecurityGroups@2023-05-01' = {
  name: '${resourcePrefix}-app1-web-asg'
  location: location
  tags: tags
}

// ============================================
// Network Security Groups
// ============================================

// NSG for Subnet 1 (VMSS/Web Tier)
resource subnet1Nsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: '${resourcePrefix}-app1-subnet1-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowHTTPInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: [
            '80'
            '443'
          ]
          description: 'Allow HTTP/HTTPS from Internet via Load Balancer'
        }
      }
      {
        name: 'AllowBastionSSH'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnetAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
          description: 'Allow SSH from Bastion'
        }
      }
      {
        name: 'DenySSHFromInternet'
        properties: {
          priority: 200
          direction: 'Inbound'
          access: 'Deny'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
          description: 'Block SSH from Internet'
        }
      }
      {
        name: 'DenyRDPFromInternet'
        properties: {
          priority: 210
          direction: 'Inbound'
          access: 'Deny'
          protocol: 'Tcp'
          sourceAddressPrefix: 'Internet'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
          description: 'Block RDP from Internet'
        }
      }
    ]
  }
}

// NSG for Subnet 2 (Database Tier)
resource subnet2Nsg 'Microsoft.Network/networkSecurityGroups@2023-05-01' = {
  name: '${resourcePrefix}-app1-subnet2-nsg'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowFromSubnet1'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourceAddressPrefix: cidrSubnet(app1VnetAddressPrefix, 24, 0) // Subnet 1
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
          description: 'Allow all traffic from Subnet 1'
        }
      }
      {
        name: 'AllowBastionSSH'
        properties: {
          priority: 110
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: bastionSubnetAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
          description: 'Allow SSH from Bastion'
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
// App 1 Virtual Network
// ============================================
resource app1Vnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: '${resourcePrefix}-app1-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        app1VnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'WebSubnet'
        properties: {
          addressPrefix: cidrSubnet(app1VnetAddressPrefix, 24, 0) // 10.1.0.0/24
          networkSecurityGroup: {
            id: subnet1Nsg.id
          }
          routeTable: {
            id: spokeRouteTableId
          }
        }
      }
      {
        name: 'DatabaseSubnet'
        properties: {
          addressPrefix: cidrSubnet(app1VnetAddressPrefix, 24, 1) // 10.1.1.0/24
          networkSecurityGroup: {
            id: subnet2Nsg.id
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
// Public Load Balancer for VMSS
// ============================================
resource lbPublicIp 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: '${resourcePrefix}-app1-lb-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource loadBalancer 'Microsoft.Network/loadBalancers@2023-05-01' = {
  name: '${resourcePrefix}-app1-lb'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'LoadBalancerFrontEnd'
        properties: {
          publicIPAddress: {
            id: lbPublicIp.id
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'VMSSBackendPool'
      }
    ]
    probes: [
      {
        name: 'httpProbe'
        properties: {
          protocol: 'Http'
          port: 80
          requestPath: '/'
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'HTTPRule'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', '${resourcePrefix}-app1-lb', 'LoadBalancerFrontEnd')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', '${resourcePrefix}-app1-lb', 'VMSSBackendPool')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', '${resourcePrefix}-app1-lb', 'httpProbe')
          }
          protocol: 'Tcp'
          frontendPort: 80
          backendPort: 80
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
          loadDistribution: 'Default'
        }
      }
      {
        name: 'HTTPSRule'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', '${resourcePrefix}-app1-lb', 'LoadBalancerFrontEnd')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', '${resourcePrefix}-app1-lb', 'VMSSBackendPool')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', '${resourcePrefix}-app1-lb', 'httpProbe')
          }
          protocol: 'Tcp'
          frontendPort: 443
          backendPort: 443
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
          loadDistribution: 'Default'
        }
      }
    ]
    inboundNatPools: [
      {
        name: 'natPool'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', '${resourcePrefix}-app1-lb', 'LoadBalancerFrontEnd')
          }
          protocol: 'Tcp'
          frontendPortRangeStart: 50000
          frontendPortRangeEnd: 50099
          backendPort: 22
        }
      }
    ]
  }
}

// ============================================
// Linux VMSS with System Assigned Identity
// ============================================
 resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2023-09-01' = {
  name: '${resourcePrefix}-app1-vmss'
  location: location
  tags: union(tags, { 'arpio-config:admin-password-secret': 'https://${keyVault.name}${environment().suffixes.keyvaultDns}/secrets/AdminPassword' })
  sku: {
    name: vmSizeLinux
    tier: 'Standard'
    capacity: vmssInstanceCount
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    overprovision: false
    upgradePolicy: {
      mode: 'Manual'
    }
    virtualMachineProfile: {
      storageProfile: {
        imageReference: {
          publisher: 'Canonical'
          offer: '0001-com-ubuntu-server-jammy'
          sku: '22_04-lts-arm64'
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          caching: 'ReadWrite'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      }
      osProfile: {
        computerNamePrefix: '${resourcePrefix}web'
        adminUsername: adminUsername
        adminPassword: adminPassword
        linuxConfiguration: {
          disablePasswordAuthentication: false
        }
        customData: base64('''#!/bin/bash
          apt-get update
          apt-get install -y nginx
          systemctl start nginx
          systemctl enable nginx
          echo "<h1>App 1 Web Server - $(hostname)</h1>" > /var/www/html/index.html
        ''')
      }
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: '${resourcePrefix}-app1-vmss-nic'
            properties: {
              primary: true
              ipConfigurations: [
                {
                  name: 'ipconfig1'
                  properties: {
                    subnet: {
                      id: '${app1Vnet.id}/subnets/WebSubnet'
                    }
                    loadBalancerBackendAddressPools: [
                      {
                        id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancer.name, 'VMSSBackendPool')
                      }
                    ]
                    loadBalancerInboundNatPools: [
                      {
                        id: resourceId('Microsoft.Network/loadBalancers/inboundNatPools', loadBalancer.name, 'natPool')
                      }
                    ]
                    applicationSecurityGroups: [
                      {
                        id: webAsg.id
                      }
                    ]
                  }
                }
              ]
            }
          }
        ]
      }
    }
  }
} 

// ============================================
// Linux Database VM in Subnet 2
// ============================================
resource dbNic 'Microsoft.Network/networkInterfaces@2023-05-01' = {
  name: '${resourcePrefix}-app1-db-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: '${app1Vnet.id}/subnets/DatabaseSubnet'
          }
        }
      }
    ]
  }
}

resource dbVm 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: '${resourcePrefix}-app1-db-vm'
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSizeLinux
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-arm64'
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
      computerName: '${resourcePrefix}db'
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: dbNic.id
        }
      ]
    }
  }
}

// ============================================
// Key Vault with Admin Password Secret
// ============================================
resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: '${resourcePrefix}-app1-kv'
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

resource adminPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'AdminPassword'
  properties: {
    value: adminPassword
  }
}

// ============================================
// Outputs
// ============================================
output app1VnetId string = app1Vnet.id
output app1VnetName string = app1Vnet.name
output webSubnetId string = '${app1Vnet.id}/subnets/WebSubnet'
output databaseSubnetId string = '${app1Vnet.id}/subnets/DatabaseSubnet'
output loadBalancerPublicIp string = lbPublicIp.properties.ipAddress
output vmssId string = vmss.id
output vmssName string = vmss.name
output vmssPrincipalId string = vmss.identity.principalId 
output dbVmId string = dbVm.id
output dbVmPrivateIp string = dbNic.properties.ipConfigurations[0].properties.privateIPAddress
output webAsgId string = webAsg.id
