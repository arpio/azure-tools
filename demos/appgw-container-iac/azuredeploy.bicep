// ============================================================================
// App Gateway + Container Instances Demo
//
// Deploys: Application Gateway → 2x ACI container groups → Key Vault,
//          Blob Storage, and Queue Storage (all via private endpoints).
//
// Traffic flow:
//   Internet → App Gateway (public IP, port 80)
//            → ACI containers (private IPs, port 8000)
//            → Key Vault / Storage via private endpoints
//
// The ACR is created separately by build_image.sh and lives in its own
// resource group so it can be reused across demos.
// ============================================================================

// ---------- Parameters ----------

param location string

@description('Base name used to derive resource names')
param baseName string = 'appgw-aci'

@description('Name of the existing Azure Container Registry (created by build_image.sh)')
param acrName string

@description('Resource group where the ACR lives (separate from this deployment)')
param acrResourceGroup string

@description('Full container image URI, e.g. myacr.azurecr.io/demo-app:latest')
param containerImage string

// ---------- Variables ----------

// Deterministic unique suffix derived from subscription + resource group + deployment name.
// Used to generate globally unique names for storage accounts and key vaults.
var uniqueSuffix = uniqueString(subscription().id, resourceGroup().id, deployment().name)
var vnetName = 'vnet-${baseName}'
var storageAccountName = toLower('st${uniqueSuffix}')
var kvName = 'kv-${uniqueSuffix}'
var blobContainerName = 'demo-blobs'
var queueName = 'demo-queue'

// ============================================================================
// NETWORKING
//
// VNet: 10.1.0.0/16 with three subnets:
//   - subnet-appgw (10.1.0.0/24): Application Gateway (requires dedicated subnet)
//   - subnet-aci   (10.1.1.0/24): ACI container groups (delegated to ACI service)
//   - subnet-pe    (10.1.2.0/24): Private endpoints for Key Vault and Storage
//
// NSGs restrict traffic between subnets:
//   - App Gateway subnet: allow HTTP/HTTPS from internet + Azure Gateway Manager
//   - ACI subnet: allow port 8000 from App Gateway subnet only
//   - PE subnet: allow HTTPS from ACI subnet only
// ============================================================================

// NSG for App Gateway subnet
// Must allow GatewayManager on ports 65200-65535 for Azure to manage the gateway
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

// NSG for ACI subnet - only allows traffic from the App Gateway subnet
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
          sourceAddressPrefix: '10.1.0.0/24' // App Gateway subnet
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

// NSG for private endpoint subnet - only allows HTTPS from ACI subnet
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
          sourceAddressPrefix: '10.1.1.0/24' // ACI subnet
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

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
        // ACI requires a delegated subnet — Azure manages the network interfaces
        // for container groups placed here
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

// ============================================================================
// ACR (existing - created by build_image.sh in a separate resource group)
//
// Referenced cross-resource-group so we can read its loginServer property
// and set up identity-based image pulls.
// ============================================================================

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
  scope: resourceGroup(acrResourceGroup)
}

// ============================================================================
// STORAGE ACCOUNT
//
// Hosts the demo blob container and queue. Public access is denied —
// the ACI containers reach it through private endpoints in subnet-pe.
// The 'bypass: AzureServices' allows Azure-internal operations.
// ============================================================================

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

// ============================================================================
// KEY VAULT
//
// Stores demo secrets. Uses RBAC authorization (no access policies).
// Public access is denied — ACI containers reach it via private endpoint.
// ============================================================================

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

// ============================================================================
// PRIVATE DNS ZONES + PRIVATE ENDPOINTS
//
// Each private endpoint gets a private IP in subnet-pe and a DNS record in
// the corresponding privatelink zone. When ACI containers (in the same VNet)
// resolve e.g. "stXXX.blob.core.windows.net", the private DNS zone returns
// the private IP instead of the public one, so traffic stays in the VNet.
//
// Three private endpoints:
//   - Blob Storage  → privatelink.blob.core.windows.net
//   - Queue Storage → privatelink.queue.core.windows.net
//   - Key Vault     → privatelink.vaultcore.azure.net
// ============================================================================

// --- DNS Zones ---

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

// --- VNet links: connect each DNS zone to the VNet so DNS resolution works ---

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

// --- Private Endpoints + DNS Zone Groups ---
// Each endpoint creates a NIC in subnet-pe. The DNS zone group automatically
// registers an A record in the private DNS zone pointing to that NIC's IP.

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

// ============================================================================
// MANAGED IDENTITY + ROLE ASSIGNMENTS
//
// A single user-assigned managed identity is shared by both ACI container
// groups. It needs:
//   - Key Vault Secrets Officer: read + write secrets via the app
//   - Storage Blob Data Contributor: read + write blobs via the app
//   - Storage Queue Data Contributor: send + receive queue messages via the app
//   - AcrPull: pull container images from the ACR (cross-resource-group)
//
// The app receives the identity's client ID via the AZURE_CLIENT_ID env var
// and uses DefaultAzureCredential to authenticate to all services.
// ============================================================================

resource aciIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-aci'
  location: location
}

// --- Role assignments on Key Vault ---

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

// --- Role assignments on Storage Account ---

resource aciBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, aciIdentity.id, 'Storage Blob Data Contributor')
  scope: storageAccount
  properties: {
    // Storage Blob Data Contributor: ba92f5b4-2d11-453d-a403-e96b0029c9fe
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: aciIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource aciQueueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, aciIdentity.id, 'Storage Queue Data Contributor')
  scope: storageAccount
  properties: {
    // Storage Queue Data Contributor: 974c5e8b-45b9-4653-ba55-5f855dd0fb88
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '974c5e8b-45b9-4653-ba55-5f855dd0fb88')
    principalId: aciIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// --- AcrPull role on the container registry ---
// This is a cross-resource-group role assignment (ACR is in a different RG),
// so it must use a Bicep module — Bicep doesn't allow inline resources to
// target a different scope than the main deployment.

module aciAcrPullRole 'acrPullRole.bicep' = {
  name: 'acr-pull-role-assignment'
  scope: resourceGroup(acrResourceGroup)
  params: {
    acrName: acrName
    principalId: aciIdentity.properties.principalId
  }
}

// ============================================================================
// ACI CONTAINER GROUPS (x2)
//
// Two identical container groups running the demo Flask app. Each gets a
// private IP in subnet-aci. The App Gateway load balances across both.
//
// Image pull: uses the managed identity with AcrPull role (no admin passwords).
// This is better for DR — after Arpio recovery, the identity and role
// assignment are recreated, so image pulls keep working without manual
// password updates.
//
// Environment variables tell the app where to find each Azure service.
// AZURE_CLIENT_ID tells DefaultAzureCredential which managed identity to use.
// ============================================================================

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
        identity: aciIdentity.id
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
          environmentVariables: concat(aciEnvVars, [
            { name: 'CONTAINER_NAME', value: '${baseName}-aci-1' }
          ])
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
    aciAcrPullRole
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
        identity: aciIdentity.id
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
          environmentVariables: concat(aciEnvVars, [
            { name: 'CONTAINER_NAME', value: '${baseName}-aci-2' }
          ])
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
    aciAcrPullRole
  ]
}

// ============================================================================
// APPLICATION GATEWAY
//
// Standard_v2 SKU with autoscale (1-2 capacity units).
// Listens on port 80 (HTTP) and forwards to the two ACI private IPs on port 8000.
// Health probe hits /health on each backend to detect unhealthy containers.
//
// The App Gateway needs its own dedicated subnet (subnet-appgw) — this is an
// Azure requirement. It gets a public IP with a DNS label so the app is
// accessible via a stable FQDN.
//
// Note: resourceId() is used for self-references within the App Gateway
// definition to avoid circular reference errors in Bicep.
// ============================================================================

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
    // Backend pool with the two ACI private IPs
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
