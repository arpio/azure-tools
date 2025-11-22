// Parameters
param location string
param vmAdminUsername string
param sshPublicKey string
param vmSku string
param instanceCount int = 2
param baseName string = 'app-sql'
param sqlAdminLogin string
param sqlDbName string

// This is NOT a good way to generate a password for production use!
// In production we would generate it outside this template and put it in the Key Vault
@secure()
param sqlAdminPassword string = 'Aa1!${uniqueString(resourceGroup().id) }'

// Variables
var vnetName   = 'vnet-app'
var subnetName = 'subnet-app'
var nsgName    = 'nsg-app'
var pipName    = 'pip-lb'
var pipDomainNameLabel = 'pip-lb-${uniqueString(resourceGroup().id)}'
var lbName     = 'lb-app'
var bepoolName = 'lb-be'
var probeName  = 'http-probe'
var uniqueSuffix = uniqueString(subscription().id, resourceGroup().id, deployment().name) // 13 chars
var sqlServerName = toLower('${baseName}-${uniqueSuffix}')
var kvName = 'kv-psswd-${uniqueSuffix}'

// Build the URL once (this creates an implicit dependency on sqlKv)
var kvSecretUrl = 'https://${sqlKv.name}${environment().suffixes.keyvaultDns}/secrets/${sqlServerName}'


// NSG
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-ssh'
        properties: {
          priority: 1000
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '22'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'allow-http'
        properties: {
          priority: 1010
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// VNet
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: [ '10.0.0.0/16' ] }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.0.0.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

// Public IP
resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: pipName
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: pipDomainNameLabel 
    }
  }
}

// Load Balancer (no self-references)
resource lb 'Microsoft.Network/loadBalancers@2023-11-01' = {
  name: lbName
  location: location
  sku: { name: 'Standard' }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'fe-ip'
        properties: {
          publicIPAddress: { id: pip.id }
        }
      }
    ]
    backendAddressPools: [
      { name: bepoolName }
    ]
    probes: [
      {
        name: probeName
        properties: { protocol: 'Tcp', port: 80, intervalInSeconds: 5, numberOfProbes: 2 }
      }
    ]
    loadBalancingRules: [
      {
        name: 'http-rule'
        properties: {
          // Use resourceId() instead of lb.id within lb declaration
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', lbName, 'fe-ip')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, bepoolName)
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, probeName)
          }
          protocol: 'Tcp'
          frontendPort: 80
          backendPort: 80
          idleTimeoutInMinutes: 4
          enableFloatingIP: false
          loadDistribution: 'Default'
        }
      }
    ]
  }
}

// VMSS (reference LB subresources via resourceId(); escape $ in customData)
resource vmss 'Microsoft.Compute/virtualMachineScaleSets@2023-09-01' = {
  name: 'vmss-app'
  location: location
  sku: { name: vmSku, tier: 'Standard', capacity: instanceCount }
  properties: {
    upgradePolicy: { mode: 'Rolling' }
    virtualMachineProfile: {
      storageProfile: {
        imageReference: {
          publisher: 'Canonical'
          offer: '0001-com-ubuntu-server-jammy'
          sku: '22_04-lts'
          version: 'latest'
        }
        osDisk: {
          createOption: 'FromImage'
          managedDisk: { storageAccountType: 'Standard_LRS' }
        }
      }
      osProfile: {
        computerNamePrefix: 'vmss'
        adminUsername: vmAdminUsername
        linuxConfiguration: {
          disablePasswordAuthentication: true
          ssh: {
            publicKeys: [
              {
                path: '/home/${vmAdminUsername}/.ssh/authorized_keys'
                keyData: sshPublicKey
              }
            ]
          }
        }
        // Escape $ in $(hostname) as \$ to avoid BCP006
        customData: base64('''#!/bin/bash
        set -euxo pipefail
        export DEBIAN_FRONTEND=noninteractive

        apt-get update
        apt-get install -y nginx

        systemctl enable nginx
        systemctl start nginx

        echo "Hello from $(hostname)" > /var/www/html/index.html
        ''')        
      }
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            name: 'nicconfig1'
            properties: {
              primary: true
              ipConfigurations: [
                {
                  name: 'ipconfig1'
                  properties: {
                    subnet: {
                      id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetName)
                    }
                    loadBalancerBackendAddressPools: [
                      {
                        id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, bepoolName)
                      }
                    ]
                  }
                }
              ]
            }
          }
        ]
        // Required for Rolling upgrades: point to LB probe via resourceId()
        healthProbe: {
          id: resourceId('Microsoft.Network/loadBalancers/probes', lbName, probeName)
        }
      }
    }
  }
  dependsOn: [
    lb
  ]
  // vnet dependency is inferred; lb isn’t strictly required as dependsOn when using resourceId(),
  // but you can add it if you want to force order.
  // dependsOn: [ lb ]
}

// ---------- AUTOSCALE FOR VMSS (add after your VMSS) ----------
resource vmssAutoscale 'Microsoft.Insights/autoscaleSettings@2022-10-01' = {
  name: 'autoscale-vmss'
  location: location
  properties: {
    enabled: true
    name: 'autoscale-vmss'
    targetResourceUri: vmss.id
    profiles: [
      {
        name: 'default'
        capacity: {
          minimum: '2'
          maximum: '4'
          default: '2'
        }
        rules: [
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricNamespace: ''
              metricResourceUri: vmss.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT10M'
              timeAggregation: 'Average'
              operator: 'GreaterThan'
              threshold: 70
            }
            scaleAction: {
              direction: 'Increase'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT5M'
            }
          }
          {
            metricTrigger: {
              metricName: 'Percentage CPU'
              metricNamespace: ''
              metricResourceUri: vmss.id
              timeGrain: 'PT1M'
              statistic: 'Average'
              timeWindow: 'PT10M'
              timeAggregation: 'Average'
              operator: 'LessThan'
              threshold: 30
            }
            scaleAction: {
              direction: 'Decrease'
              type: 'ChangeCount'
              value: '1'
              cooldown: 'PT5M'
            }
          }
        ]
      }
    ]
  }
}


// NIC for the standalone VM, attached to the LB backend pool
resource nicStandalone 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'nic-standalone'
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, subnetName)
          }
          loadBalancerBackendAddressPools: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', lbName, bepoolName)
            }
          ]
        }
      }
    ]
  }
  dependsOn: [
    vnet
    lb
  ]
}

// Standalone Linux VM (no public IP; traffic comes via the LB)
resource vmStandalone 'Microsoft.Compute/virtualMachines@2023-09-01' = {
  name: 'vm-standalone'
  location: location
  properties: {
    hardwareProfile: {
      vmSize: vmSku  // reuse your param (e.g., Standard_A1_v2)
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'Standard_LRS' }
      }
    }
    osProfile: {
      computerName: 'vm-standalone'
      adminUsername: vmAdminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${vmAdminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
      // Same user-data style you used for VMSS
      customData: base64('''#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y nginx
systemctl enable nginx
systemctl start nginx
echo "Hello from $(hostname)" > /var/www/html/index.html
''')
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nicStandalone.id
          properties: { primary: true }
        }
      ]
    }
  }
}

// ---------- AZURE SQL: SERVER, FIREWALL RULES, DATABASE ----------

// Key-vault
// Must use RBAC access
resource sqlKv 'Microsoft.KeyVault/vaults@2025-05-01' = {
  name: kvName
  location: location
  properties: {
    sku: { name: 'standard', family: 'A' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    accessPolicies: null
    enabledForDeployment: false
    enabledForTemplateDeployment: true
  }
}

// Secret in key-vault
resource sqlAdminPwdSecret 'Microsoft.KeyVault/vaults/secrets@2025-05-01' = {
  name: sqlServerName
  parent: sqlKv
  properties: {
    value: sqlAdminPassword
  }
}

// The following will NOT work here, because I am creating the K-V secret
// here.  In the future we would do this 2-stage. First create teh K-V and
// secret outside the template, then deploy the template that reads it.

// Read the secret value from Key Vault
// var sqlAdminPasswordFromKv = listSecret(
//   resourceId('Microsoft.KeyVault/vaults/secrets', sqlKv.name, sqlServerName),
//   '2016-10-01'  // Secret management API version
// ).value

resource sql 'Microsoft.Sql/servers@2023-08-01' = {
  name: sqlServerName
  location: location
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
    publicNetworkAccess: 'Enabled'
    version: '12.0'
  }
  // add tag arpio-config:sql-admin-password-secret with value pointing to the URL of the secret
  tags: {
    // Arpio requires this
    // NOTE: must be computable at start of deployment, so we
    // construct the "latest" secret URL (no version segment)
    'arpio-config:sql-admin-password-secret': kvSecretUrl
  }
}

resource fwAllowAzure 'Microsoft.Sql/servers/firewallRules@2023-08-01' = {
  name: 'AllowAllAzureServices'
  parent: sql
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource fwAllowAllIP 'Microsoft.Sql/servers/firewallRules@2023-08-01' = {
  name: 'AllowAllIP'
  parent: sql
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '255.255.255.255'
  }
}

resource sqldb 'Microsoft.Sql/servers/databases@2023-08-01' = {
  name: sqlDbName
  parent: sql
  location: location
  sku: {
    name: 'GP_Gen5_2'
    tier: 'GeneralPurpose'
    capacity: 2
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 268435456000
  }
}


// Output: prefer resource symbol property (no reference())
output loadBalancerPublicIP string = pip.properties.ipAddress
output loadBalancerFQDN string = pip.properties.dnsSettings.fqdn
output sqlServerFqdn string = sql.properties.fullyQualifiedDomainName
output sqlAdminPwdSecretUrl string = kvSecretUrl
