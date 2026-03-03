// ============================================
// Standalone PaaS Application Module
// ============================================
// Deploys PaaS resources without any VNet dependencies:
// - Application Gateway (with its own public IP)
// - App Service
// - Azure SQL Server + Database
// - Key Vault
// - Storage Account
// - Container Instance

@description('Resource name prefix')
param resourcePrefix string

@description('Location for all resources')
param location string

@description('Secret value for Key Vault')
@secure()
param secretValue string

@description('SQL Administrator username')
param sqlAdminUsername string

@description('SQL Administrator password')
@secure()
param sqlAdminPassword string

@description('Tags to apply to all resources')
param tags object = {}

// ============================================
// Key Vault
// ============================================
resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: '${resourcePrefix}-kv'
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
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// Store the application secret
resource secret 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'AppSecret'
  properties: {
    value: secretValue
  }
}

// Store the SQL Database password
resource dbPasswordSecret 'Microsoft.KeyVault/vaults/secrets@2023-02-01' = {
  parent: keyVault
  name: 'DBPassword'
  properties: {
    value: sqlAdminPassword
  }
}

// ============================================
// Storage Account
// ============================================
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: toLower(replace('${resourcePrefix}sa', '-', ''))
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

// Blob service
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

// Blob containers
resource container1 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'container1'
  properties: {
    publicAccess: 'None'
  }
}

resource container2 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'container2'
  properties: {
    publicAccess: 'None'
  }
}

// Queue service
resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

// Queue
resource queue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-01-01' = {
  parent: queueService
  name: 'queue1'
}

// ============================================
// Azure SQL Server and Database
// ============================================
resource sqlServer 'Microsoft.Sql/servers@2023-05-01-preview' = {
  name: '${resourcePrefix}-sql'
  location: location
  tags: {
    'arpio-config:admin-password-secret': 'https://${keyVault.name}.vault.azure.net/secrets/DBPassword'
  } 
  properties: {
    administratorLogin: sqlAdminUsername
    administratorLoginPassword: sqlAdminPassword
    version: '12.0'
    publicNetworkAccess: 'Enabled' // No private endpoint - standalone
    minimalTlsVersion: '1.2'
  }
}

// Allow Azure services to access SQL Server
resource sqlFirewallRule 'Microsoft.Sql/servers/firewallRules@2023-05-01-preview' = {
  parent: sqlServer
  name: 'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-05-01-preview' = {
  parent: sqlServer
  name: '${resourcePrefix}-db'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
    tier: 'Basic'
    capacity: 5
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    maxSizeBytes: 2147483648 // 2 GB
  }
}

// ============================================
// App Service Plan and Web App
// ============================================
resource appServicePlan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: '${resourcePrefix}-asp'
  location: location
  tags: tags
  sku: {
    name: 'P1v3'
    tier: 'PremiumV3'
    capacity: 1
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

resource webApp 'Microsoft.Web/sites@2023-01-01' = {
  name: '${resourcePrefix}-webapp'
  location: location
  tags: tags
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOTNETCORE|8.0'
      alwaysOn: true
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      appSettings: [
        {
          name: 'ASPNETCORE_ENVIRONMENT'
          value: 'Production'
        }
        {
          name: 'AppSecret'
          value: '@Microsoft.KeyVault(VaultName=${keyVault.name};SecretName=AppSecret)'
        }
      ]
      connectionStrings: [
        {
          name: 'SqlConnectionString'
          connectionString: 'Server=tcp:${sqlServer.properties.fullyQualifiedDomainName},1433;Initial Catalog=${sqlDatabase.name};Persist Security Info=False;User ID=${sqlAdminUsername};Password=${sqlAdminPassword};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;'
          type: 'SQLAzure'
        }
      ]
      ipSecurityRestrictions: [
        {
          ipAddress: appGatewayVnet.properties.subnets[0].properties.addressPrefix
          action: 'Allow'
          priority: 100
          name: 'AllowAppGatewaySubnet'
          description: 'Allow traffic only from Application Gateway subnet'
        }
        {
          ipAddress: '0.0.0.0/0'
          action: 'Deny'
          priority: 200
          name: 'DenyAllOther'
          description: 'Deny all other traffic'
        }
      ]
    }
  }
}

// Grant App Service access to Key Vault (RBAC)
resource keyVaultRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, webApp.id, 'Key Vault Secrets User')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6') // Key Vault Secrets User
    principalId: webApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ============================================
// Container Instance (standalone with public IP)
// ============================================
resource containerGroup 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: '${resourcePrefix}-aci'
  location: location
  tags: tags
  properties: {
    containers: [
      {
        name: 'app-container'
        properties: {
          image: 'mcr.microsoft.com/azuredocs/aci-helloworld:latest'
          ports: [
            {
              port: 8080
              protocol: 'TCP'
            }
          ]
          resources: {
            requests: {
              cpu: 1
              memoryInGB: 1
            }
          }
          environmentVariables: [
            {
              name: 'PORT'
              value: '8080'
            }
          ]
        }
      }
    ]
    osType: 'Linux'
    restartPolicy: 'Always'
    ipAddress: {
      type: 'Public'
      ports: [
        {
          port: 8080
          protocol: 'TCP'
        }
      ]
      dnsNameLabel: '${resourcePrefix}-aci'
    }
  }
}

// ============================================
// Application Gateway
// ============================================

// Public IP for Application Gateway
resource appGatewayPublicIp 'Microsoft.Network/publicIPAddresses@2023-05-01' = {
  name: '${resourcePrefix}-appgw-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

// VNet for Application Gateway only
resource appGatewayVnet 'Microsoft.Network/virtualNetworks@2023-05-01' = {
  name: '${resourcePrefix}-appgw-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.254.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'AppGatewaySubnet'
        properties: {
          addressPrefix: '10.254.0.0/24'
        }
      }
    ]
  }
}

resource applicationGateway 'Microsoft.Network/applicationGateways@2023-05-01' = {
  name: '${resourcePrefix}-appgw'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
      capacity: 2
    }
    gatewayIPConfigurations: [
      {
        name: 'appGatewayIpConfig'
        properties: {
          subnet: {
            id: '${appGatewayVnet.id}/subnets/AppGatewaySubnet'
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appGatewayFrontendIP'
        properties: {
          publicIPAddress: {
            id: appGatewayPublicIp.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port_80'
        properties: {
          port: 80
        }
      }
      {
        name: 'port_443'
        properties: {
          port: 443
        }
      }
      {
        name: 'port_8080'
        properties: {
          port: 8080
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'appServiceBackendPool'
        properties: {
          backendAddresses: [
            {
              fqdn: webApp.properties.defaultHostName
            }
          ]
        }
      }
      {
        name: 'containerInstanceBackendPool'
        properties: {
          backendAddresses: [
            {
              fqdn: containerGroup.properties.ipAddress.fqdn
            }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'appServiceHttpSettings'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
          requestTimeout: 30
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', '${resourcePrefix}-appgw', 'appServiceProbe')
          }
        }
      }
      {
        name: 'containerInstanceHttpSettings'
        properties: {
          port: 8080
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
          requestTimeout: 30
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', '${resourcePrefix}-appgw', 'containerInstanceProbe')
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'httpListener80'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', '${resourcePrefix}-appgw', 'appGatewayFrontendIP')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', '${resourcePrefix}-appgw', 'port_80')
          }
          protocol: 'Http'
          requireServerNameIndication: false
        }
      }
      {
        name: 'httpListener8080'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', '${resourcePrefix}-appgw', 'appGatewayFrontendIP')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', '${resourcePrefix}-appgw', 'port_8080')
          }
          protocol: 'Http'
          requireServerNameIndication: false
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'routeToAppService80'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', '${resourcePrefix}-appgw', 'httpListener80')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', '${resourcePrefix}-appgw', 'appServiceBackendPool')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', '${resourcePrefix}-appgw', 'appServiceHttpSettings')
          }
        }
      }
      {
        name: 'routeToContainer8080'
        properties: {
          ruleType: 'Basic'
          priority: 120
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', '${resourcePrefix}-appgw', 'httpListener8080')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', '${resourcePrefix}-appgw', 'containerInstanceBackendPool')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', '${resourcePrefix}-appgw', 'containerInstanceHttpSettings')
          }
        }
      }
    ]
    probes: [
      {
        name: 'appServiceProbe'
        properties: {
          protocol: 'Https'
          path: '/'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: true
          minServers: 0
        }
      }
      {
        name: 'containerInstanceProbe'
        properties: {
          protocol: 'Http'
          path: '/'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: true
          minServers: 0
        }
      }
    ]
  }
}

// ============================================
// Outputs
// ============================================
output keyVaultId string = keyVault.id
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
output sqlServerId string = sqlServer.id
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output databaseName string = sqlDatabase.name
output webAppId string = webApp.id
output webAppName string = webApp.name
output webAppDefaultHostname string = webApp.properties.defaultHostName
output webAppUrl string = 'https://${webApp.properties.defaultHostName}'
output containerGroupId string = containerGroup.id
output containerInstanceFqdn string = containerGroup.properties.ipAddress.fqdn
output containerInstanceIp string = containerGroup.properties.ipAddress.ip
output containerInstanceUrl string = 'http://${containerGroup.properties.ipAddress.fqdn}:8080'
output applicationGatewayId string = applicationGateway.id
output appGatewayPublicIp string = appGatewayPublicIp.properties.ipAddress
output appGatewayUrl string = 'http://${appGatewayPublicIp.properties.ipAddress}'
output appGatewayContainerUrl string = 'http://${appGatewayPublicIp.properties.ipAddress}:8080'
