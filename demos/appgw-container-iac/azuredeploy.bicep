// Parameters
param location string
param baseName string = 'appgw-aci'
param acrName string
param acrResourceGroup string
param containerImage string

// Variables
var uniqueSuffix = uniqueString(subscription().id, resourceGroup().id, deployment().name)
var vnetName = 'vnet-${baseName}'
var storageAccountName = toLower('st${uniqueSuffix}')
var kvName = 'kv-${uniqueSuffix}'
var blobContainerName = 'demo-blobs'
var queueName = 'demo-queue'

// ---------- NSGs ----------

resource nsgAppGw 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-appgw'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-http'
        properties: {
          priority: 1000
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '80'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'allow-https'
        properties: {
          priority: 1010
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'allow-gateway-manager'
        properties: {
          priority: 1020
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '65200-65535'
          sourceAddressPrefix: 'GatewayManager'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource nsgAci 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-aci'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-appgw-to-aci'
        properties: {
          priority: 1000
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '8000'
          sourceAddressPrefix: '10.1.0.0/24'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource nsgPe 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-pe'
  location: location
  properties: {
    securityRules: [
      {
        name: 'allow-aci-to-pe'
        properties: {
          priority: 1000
          access: 'Allow'
          direction: 'Inbound'
          protocol: 'Tcp'
          sourcePortRange: '*'
          destinationPortRange: '443'
          sourceAddressPrefix: '10.1.1.0/24'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// ---------- VNet ----------

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.1.0.0/16'] }
    subnets: [
      {
        name: 'subnet-appgw'
        properties: {
          addressPrefix: '10.1.0.0/24'
          networkSecurityGroup: { id: nsgAppGw.id }
        }
      }
      {
        name: 'subnet-aci'
        properties: {
          addressPrefix: '10.1.1.0/24'
          networkSecurityGroup: { id: nsgAci.id }
          delegations: [
            {
              name: 'aci-delegation'
              properties: {
                serviceName: 'Microsoft.ContainerInstance/containerGroups'
              }
            }
          ]
        }
      }
      {
        name: 'subnet-pe'
        properties: {
          addressPrefix: '10.1.2.0/24'
          networkSecurityGroup: { id: nsgPe.id }
        }
      }
    ]
  }
}

// ---------- ACR (existing, referenced) ----------

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
  scope: resourceGroup(acrResourceGroup)
}

// ---------- Storage Account ----------

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: blobContainerName
}

resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource queue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-01-01' = {
  parent: queueService
  name: queueName
}

// ---------- Key Vault ----------

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  properties: {
    sku: { name: 'standard', family: 'A' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enabledForDeployment: false
    enabledForTemplateDeployment: true
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
    }
  }
}

// ---------- Private DNS Zones ----------

resource dnsZoneBlob 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.blob.${environment().suffixes.storage}'
  location: 'global'
}

resource dnsZoneQueue 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.queue.${environment().suffixes.storage}'
  location: 'global'
}

resource dnsZoneKv 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
}

// VNet links for each DNS zone
resource dnsZoneBlobLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsZoneBlob
  name: 'link-blob'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

resource dnsZoneQueueLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsZoneQueue
  name: 'link-queue'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

resource dnsZoneKvLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: dnsZoneKv
  name: 'link-kv'
  location: 'global'
  properties: {
    virtualNetwork: { id: vnet.id }
    registrationEnabled: false
  }
}

// ---------- Private Endpoints ----------

resource peBlobStorage 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-blob'
  location: location
  properties: {
    subnet: {
      id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'subnet-pe')
    }
    privateLinkServiceConnections: [
      {
        name: 'blob-connection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: ['blob']
        }
      }
    ]
  }
  dependsOn: [vnet]
}

resource peBlobDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: peBlobStorage
  name: 'blob-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'blob-dns-config'
        properties: {
          privateDnsZoneId: dnsZoneBlob.id
        }
      }
    ]
  }
  dependsOn: [dnsZoneBlobLink]
}

resource peQueueStorage 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-queue'
  location: location
  properties: {
    subnet: {
      id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'subnet-pe')
    }
    privateLinkServiceConnections: [
      {
        name: 'queue-connection'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: ['queue']
        }
      }
    ]
  }
  dependsOn: [vnet]
}

resource peQueueDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: peQueueStorage
  name: 'queue-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'queue-dns-config'
        properties: {
          privateDnsZoneId: dnsZoneQueue.id
        }
      }
    ]
  }
  dependsOn: [dnsZoneQueueLink]
}

resource peKeyVault 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: 'pe-kv'
  location: location
  properties: {
    subnet: {
      id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'subnet-pe')
    }
    privateLinkServiceConnections: [
      {
        name: 'kv-connection'
        properties: {
          privateLinkServiceId: keyVault.id
          groupIds: ['vault']
        }
      }
    ]
  }
  dependsOn: [vnet]
}

resource peKvDnsGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: peKeyVault
  name: 'kv-dns-group'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'kv-dns-config'
        properties: {
          privateDnsZoneId: dnsZoneKv.id
        }
      }
    ]
  }
  dependsOn: [dnsZoneKvLink]
}

// ---------- Managed Identities ----------

// Identity for ACI containers (shared by both container groups)
resource aciIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-aci'
  location: location
}

// ---------- Role Assignments - ACI Identity ----------

// Key Vault Secrets Officer (read + write secrets)
resource aciKvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, aciIdentity.id, 'Key Vault Secrets Officer')
  scope: keyVault
  properties: {
    // Key Vault Secrets Officer: b86a8fe4-44ce-4948-aee5-eccb2c155cd7
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
    principalId: aciIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Blob Data Contributor
resource aciBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, aciIdentity.id, 'Storage Blob Data Contributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: aciIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Queue Data Contributor
resource aciQueueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, aciIdentity.id, 'Storage Queue Data Contributor')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
    principalId: aciIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------- ACI Container Groups ----------

var acrCredentials = acr.listCredentials()
var aciEnvVars = [
  { name: 'KEY_VAULT_URL', value: 'https://${kvName}${environment().suffixes.keyvaultDns}' }
  { name: 'STORAGE_ACCOUNT_URL', value: 'https://${storageAccountName}.blob.${environment().suffixes.storage}' }
  { name: 'QUEUE_ACCOUNT_URL', value: 'https://${storageAccountName}.queue.${environment().suffixes.storage}' }
  { name: 'QUEUE_NAME', value: queueName }
  { name: 'BLOB_CONTAINER', value: blobContainerName }
  { name: 'AZURE_CLIENT_ID', value: aciIdentity.properties.clientId }
]

resource aciGroup1 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: '${baseName}-aci-1'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${aciIdentity.id}': {}
    }
  }
  properties: {
    osType: 'Linux'
    restartPolicy: 'Always'
    imageRegistryCredentials: [
      {
        server: acr.properties.loginServer
        username: acrCredentials.username
        password: acrCredentials.passwords[0].value
      }
    ]
    containers: [
      {
        name: 'demo-app'
        properties: {
          image: containerImage
          ports: [{ port: 8000, protocol: 'TCP' }]
          resources: {
            requests: { cpu: 1, memoryInGB: 1 }
          }
          environmentVariables: aciEnvVars
        }
      }
    ]
    ipAddress: {
      type: 'Private'
      ports: [{ port: 8000, protocol: 'TCP' }]
    }
    subnetIds: [
      {
        id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'subnet-aci')
      }
    ]
  }
  dependsOn: [
    vnet
    aciKvRole
    aciBlobRole
    aciQueueRole

  ]
}

resource aciGroup2 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: '${baseName}-aci-2'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${aciIdentity.id}': {}
    }
  }
  properties: {
    osType: 'Linux'
    restartPolicy: 'Always'
    imageRegistryCredentials: [
      {
        server: acr.properties.loginServer
        username: acrCredentials.username
        password: acrCredentials.passwords[0].value
      }
    ]
    containers: [
      {
        name: 'demo-app'
        properties: {
          image: containerImage
          ports: [{ port: 8000, protocol: 'TCP' }]
          resources: {
            requests: { cpu: 1, memoryInGB: 1 }
          }
          environmentVariables: aciEnvVars
        }
      }
    ]
    ipAddress: {
      type: 'Private'
      ports: [{ port: 8000, protocol: 'TCP' }]
    }
    subnetIds: [
      {
        id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'subnet-aci')
      }
    ]
  }
  dependsOn: [
    vnet
    aciKvRole
    aciBlobRole
    aciQueueRole

  ]
}

// ---------- Application Gateway ----------

var appGwPipName = 'pip-appgw'
var appGwName = 'appgw-${baseName}'
var appGwPipDomainLabel = 'appgw-${uniqueSuffix}'

resource appGwPip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: appGwPipName
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: appGwPipDomainLabel
    }
  }
}

resource appGw 'Microsoft.Network/applicationGateways@2023-11-01' = {
  name: appGwName
  location: location
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
    }
    autoscaleConfiguration: {
      minCapacity: 1
      maxCapacity: 2
    }
    gatewayIPConfigurations: [
      {
        name: 'appgw-ip-config'
        properties: {
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, 'subnet-appgw')
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appgw-fe-ip'
        properties: {
          publicIPAddress: { id: appGwPip.id }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port-80'
        properties: { port: 80 }
      }
    ]
    backendAddressPools: [
      {
        name: 'aci-backend-pool'
        properties: {
          backendAddresses: [
            { ipAddress: aciGroup1.properties.ipAddress.ip }
            { ipAddress: aciGroup2.properties.ipAddress.ip }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'http-settings'
        properties: {
          port: 8000
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 30
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', appGwName, 'health-probe')
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'http-listener'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', appGwName, 'appgw-fe-ip')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGwName, 'port-80')
          }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'http-rule'
        properties: {
          priority: 100
          ruleType: 'Basic'
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGwName, 'http-listener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGwName, 'aci-backend-pool')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', appGwName, 'http-settings')
          }
        }
      }
    ]
    probes: [
      {
        name: 'health-probe'
        properties: {
          protocol: 'Http'
          host: '127.0.0.1'
          path: '/health'
          port: 8000
          interval: 30
          timeout: 10
          unhealthyThreshold: 3
        }
      }
    ]
  }
  dependsOn: [vnet]
}

// ---------- Outputs ----------

output appGatewayPublicIP string = appGwPip.properties.ipAddress
output appGatewayFQDN string = appGwPip.properties.dnsSettings.fqdn
output acrLoginServer string = acr.properties.loginServer
output keyVaultUri string = 'https://${kvName}${environment().suffixes.keyvaultDns}'
output storageAccountName string = storageAccountName
output aciPrivateIP1 string = aciGroup1.properties.ipAddress.ip
output aciPrivateIP2 string = aciGroup2.properties.ipAddress.ip
