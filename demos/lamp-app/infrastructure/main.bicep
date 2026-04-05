// =============================================================================
// Azure LAMP Stack for Arpio Bug Bash (v2)
// Deploys: VNet + Subnet + NSG + Public IP + NIC + Linux VM (Apache/PHP)
//          + Azure SQL + Key Vault + Storage Account + Blob Container
//
// Azure → AWS Translation:
//   Resource Group    = CloudFormation Stack (loosely)
//   VNet              = VPC
//   Subnet            = Subnet
//   NSG               = Security Group
//   Public IP         = Elastic IP
//   NIC               = ENI
//   VM                = EC2 Instance
//   Azure SQL         = RDS (SQL Server engine)
//   Key Vault         = Secrets Manager + KMS combined
//   Storage Account   = S3 (the account is like the bucket namespace)
//   Blob Container    = S3 Bucket (where objects actually live)
// =============================================================================


// =============================================================================
// 🔧 CONFIGURATION PARAMETERS
// Change these values to customize your deployment
// =============================================================================

@description('Prefix for all resource names (e.g., "myapp", "team1", "alice")')
@minLength(3)
@maxLength(10)
param resourcePrefix string = 'LampApp'

@description('Azure region for deployment')
param location string = resourceGroup().location

@description('VM size (e.g., Standard_B2s, Standard_D2s_v3, Standard_DC2s_v3)')
param vmSize string = 'Standard_B2s'

@description('VM admin username')
param vmAdminUsername string = 'azureuser'

@description('SSH public key for VM access')
@secure()
param vmAdminSshPublicKey string

@description('SQL Server admin username')
param sqlAdminUsername string = 'sqladmin'

@description('SQL Server admin password (min 8 chars)')
@secure()
@minLength(8)
param sqlAdminPassword string

@description('Unique suffix for globally unique names (auto-generated)')
param uniqueSuffix string = uniqueString(resourceGroup().id)


// =============================================================================
// Variables
// =============================================================================

var vnetName = '${resourcePrefix}-vnet'
var subnetName = '${resourcePrefix}-subnet'
var privateEndpointSubnetName = '${resourcePrefix}-pe-subnet'
var nsgName = '${resourcePrefix}-nsg'
var publicIpName = '${resourcePrefix}-pip'
var nicName = '${resourcePrefix}-nic'
var vmName = '${resourcePrefix}-vm'
var sqlServerName = '${toLower(resourcePrefix)}-sql-${uniqueSuffix}'             // Must be globally unique
var sqlDbName = 'lampdb'
var sqlPrivateEndpointName = '${resourcePrefix}-sql-pe'
var privateDnsZoneName = 'privatelink${environment().suffixes.sqlServerHostname}'
var keyVaultName = '${toLower(resourcePrefix)}-kv-${uniqueSuffix}'                    // Must be globally unique, max 24 chars
var storageAccountName = '${toLower(replace(resourcePrefix, '-', ''))}${uniqueSuffix}'              // Must be globally unique, lowercase, no hyphens, max 24 chars
var blobContainerName = 'assets'                                 // ≈ S3 bucket (scoped within storage account)

// Application Gateway and Load Balancer names
var appGatewayName = '${resourcePrefix}-appgw'
var appGatewaySubnetName = '${resourcePrefix}-appgw-subnet'
var appGatewayPublicIpName = '${resourcePrefix}-appgw-pip'
var loadBalancerName = '${resourcePrefix}-lb'
var loadBalancerPublicIpName = '${resourcePrefix}-lb-pip'

// =============================================================================
// Network Security Group (≈ AWS Security Group)
// In Azure, NSGs are standalone resources attached to subnets or NICs.
// In AWS, Security Groups attach directly to EC2/RDS instances.
// =============================================================================
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgName
  location: location
  tags: {
    ArpioBackup: 'True'
  }
  properties: {
    securityRules: [
      {
        name: 'AllowSSH'
        properties: {
          priority: 1000                      // Lower number = higher priority (unlike AWS, which has no priority)
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'            // In production, lock this to your IP!
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'AllowHTTP'
        properties: {
          priority: 1001
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'AllowHTTPS'
        properties: {
          priority: 1002
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
    ]
  }
}

// =============================================================================
// Virtual Network (≈ AWS VPC)
// Azure VNets use address spaces (like VPC CIDR blocks).
// =============================================================================
resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  tags: {
    ArpioBackup: 'True'
  }
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'                        // ≈ VPC CIDR block
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.0.1.0/24'       // ≈ Subnet CIDR block
          networkSecurityGroup: {
            id: nsg.id
          }
          serviceEndpoints: [
            { service: 'Microsoft.KeyVault' }    // ≈ VPC Endpoint for Secrets Manager
            { service: 'Microsoft.Storage' }     // ≈ VPC Gateway Endpoint for S3
          ]
        }
      }
      {
        name: privateEndpointSubnetName
        properties: {
          addressPrefix: '10.0.2.0/24'       // Dedicated subnet for private endpoints
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
      {
        name: appGatewaySubnetName
        properties: {
          addressPrefix: '10.0.3.0/24'       // Dedicated subnet for Application Gateway (required)
        }
      }
    ]
  }
}

// =============================================================================
// Public IP Addresses (≈ AWS Elastic IPs)
// =============================================================================
resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: publicIpName
  location: location
  tags: {
    ArpioBackup: 'True'
  }
  sku: {
    name: 'Standard'                         // Standard SKU = static IP (like EIP)
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource appGatewayPublicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: appGatewayPublicIpName
  location: location
  tags: {
    ArpioBackup: 'True'
  }
  sku: {
    name: 'Standard'                         // Required for Application Gateway v2
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource loadBalancerPublicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: loadBalancerPublicIpName
  location: location
  tags: {
    ArpioBackup: 'True'
  }
  sku: {
    name: 'Standard'                         // Required for Standard Load Balancer
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// =============================================================================
// Network Interface (≈ AWS ENI - Elastic Network Interface)
// In Azure, every VM MUST have a NIC. In AWS, ENIs are implicit unless
// you create them explicitly.
// Now attached to Load Balancer backend pool
// =============================================================================
resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: nicName
  location: location
  tags: {
    ArpioBackup: 'True'
  }
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          publicIPAddress: {
            id: publicIp.id
          }
          loadBalancerBackendAddressPools: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, 'loadBalancerBackendPool')
            }
          ]
        }
      }
    ]
  }
  dependsOn: [
    loadBalancer
  ]
}

// =============================================================================
// Storage Account (≈ AWS S3 — the account/namespace level)
//
// Key difference from S3:
//   - S3 bucket names are globally unique across ALL of AWS
//   - Azure Storage Account names are globally unique, but container names
//     only need to be unique within the storage account
//   - Think: Storage Account = "your S3 namespace", Blob Container = "a bucket"
// =============================================================================
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: {
    ArpioBackup: 'True'
  }
  sku: {
    name: 'Standard_LRS'                        // ≈ S3 Standard, single-region
                                                 // Standard_GRS ≈ S3 Cross-Region Replication
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'                            // ≈ S3 Standard (vs 'Cool' ≈ S3 Infrequent Access)
    allowBlobPublicAccess: true                  // Required so the logo is publicly viewable
    minimumTlsVersion: 'TLS1_2'
  }
}

// Blob Service (intermediate resource — Azure requires this layer between account and container)
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

// =============================================================================
// Blob Container (≈ AWS S3 Bucket)
// This is where the Arpio logo and static assets live.
// publicAccess: 'Blob' = individual blobs are publicly readable (≈ public-read ACL)
// =============================================================================
resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: blobContainerName
  properties: {
    publicAccess: 'Blob'                         // ≈ S3 public-read on individual objects
  }
}

// =============================================================================
// Key Vault (≈ AWS Secrets Manager + KMS combined)
//
// In Azure, Key Vault stores:
//   - Secrets (≈ Secrets Manager — passwords, connection strings)
//   - Keys (≈ KMS — encryption keys)
//   - Certificates (≈ ACM — SSL/TLS certs)
// All in one service. AWS splits these across 3 separate services.
// =============================================================================
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: {
    ArpioBackup: 'True'
  }
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId             // ≈ AWS account ID for access control
    enabledForDeployment: true
    enabledForTemplateDeployment: true
    enableRbacAuthorization: true                 // Use Azure RBAC (≈ IAM policies)
    networkAcls: {
      defaultAction: 'Allow'                      // For bug bash simplicity
      bypass: 'AzureServices'
    }
  }
}

// Store secrets in Key Vault (≈ aws secretsmanager create-secret)
resource secretSqlUser 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'sql-admin-username'
  properties: { value: sqlAdminUsername }
}

resource secretSqlPassword 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'sql-admin-password'
  properties: { value: sqlAdminPassword }
}

resource secretSqlServer 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'sql-server-fqdn'
  properties: { value: sqlServer.properties.fullyQualifiedDomainName }
}

resource secretSqlDbName 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'sql-database-name'
  properties: { value: sqlDbName }
}

resource secretStorageUrl 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'storage-blob-url'
  properties: { value: storageAccount.properties.primaryEndpoints.blob }
}

// =============================================================================
// Virtual Machine (≈ AWS EC2 Instance)
//
// Key differences from EC2:
//   - Azure VMs require a NIC (created above)
//   - OS disk is always a Managed Disk (≈ EBS volume, auto-created)
//   - cloud-init works the same way via customData (≈ EC2 User Data)
//   - 'identity: SystemAssigned' ≈ EC2 Instance Profile with IAM Role
// =============================================================================
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  tags: {
    ArpioBackup: 'True'
  }
  identity: {
    type: 'SystemAssigned'                       // ≈ EC2 Instance Profile / IAM Role
  }
  properties: {
    // userData is accessible via IMDS and translated by Arpio during recovery
    // Similar to AWS EC2 user data, but stored separately from customData (cloud-init)
    // Use full endpoint URLs (not just names) for Arpio to translate properly
    // Arpio translates full storage endpoints but not account names alone (ambiguous)
    userData: base64(string({
      sqlServerFqdn: sqlServer.properties.fullyQualifiedDomainName
      sqlDatabaseName: sqlDbName
      keyVaultName: keyVault.name
      storageBlobEndpoint: storageAccount.properties.primaryEndpoints.blob
      appGatewayId: appGateway.id
      appGatewayName: appGatewayName
      appGatewayPublicIp: appGatewayPublicIp.properties.ipAddress
      loadBalancerId: loadBalancer.id
      loadBalancerName: loadBalancerName
      loadBalancerPublicIp: loadBalancerPublicIp.properties.ipAddress
    }))
    hardwareProfile: {
      vmSize: vmSize                    // 2 vCPU, 8 GB RAM (confidential computing SKU - available in this subscription)
    }
    osProfile: {
      computerName: vmName
      adminUsername: vmAdminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${vmAdminUsername}/.ssh/authorized_keys'
              keyData: vmAdminSshPublicKey
            }
          ]
        }
      }
      customData: base64(cloudInitScript)        // ≈ EC2 User Data (cloud-init)
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'  // ≈ gp3 EBS volume
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        { id: nic.id }
      ]
    }
  }
}

// =============================================================================
// Role Assignments (≈ Attaching IAM policies to an EC2 Instance Role)
//
// In Azure, RBAC role assignments connect:
//   principal (VM managed identity) → role → scope (resource)
// In AWS, you'd attach an IAM policy to the instance profile's role.
// =============================================================================

// VM → Key Vault Secrets User (≈ secretsmanager:GetSecretValue)
resource kvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, vm.id, '4633458b-17de-408a-b874-0445c86b69e6')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// VM → Storage Blob Data Reader (≈ s3:GetObject)
resource storageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, vm.id, '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// VM → Storage Blob Data Contributor (≈ s3:PutObject — needed to upload the logo)
resource storageWriteRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, vm.id, 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
  scope: storageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// VM → Reader on Resource Group (to query Application Gateway and Load Balancer details)
resource rgReaderRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, vm.id, 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  scope: resourceGroup()
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')  // Reader role
    principalId: vm.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// =============================================================================
// Azure SQL Server (≈ AWS RDS Instance — the logical server)
// In Azure, SQL has two layers:
//   1. SQL Server (logical) = manages logins, firewall rules
//   2. SQL Database (actual DB) = where data lives
// In AWS, RDS combines both into one "DB Instance".
// =============================================================================
resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: location
  tags: {
    ArpioBackup: 'True'
    'arpio-config:admin-password-secret': 'https://${keyVault.name}${environment().suffixes.keyvaultDns}/secrets/sql-admin-password'
  }
  properties: {
    administratorLogin: sqlAdminUsername
    administratorLoginPassword: sqlAdminPassword
    version: '12.0'
    publicNetworkAccess: 'Disabled'  // Private endpoint only - no public access
  }
}

// =============================================================================
// Private DNS Zone for SQL Server Private Endpoint
// =============================================================================
resource sqlPrivateDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: privateDnsZoneName
  location: 'global'
  tags: {
    ArpioBackup: 'True'
  }
}

resource sqlPrivateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: sqlPrivateDnsZone
  name: '${vnetName}-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnet.id
    }
  }
}

// =============================================================================
// SQL Server Private Endpoint (≈ AWS PrivateLink for RDS)
// =============================================================================
resource sqlPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-11-01' = {
  name: sqlPrivateEndpointName
  location: location
  tags: {
    ArpioBackup: 'True'
  }
  properties: {
    subnet: {
      id: vnet.properties.subnets[1].id  // Private endpoint subnet
    }
    privateLinkServiceConnections: [
      {
        name: sqlPrivateEndpointName
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: [
            'sqlServer'
          ]
        }
      }
    ]
  }
}

// Private DNS Zone Group - Auto-creates A record for SQL Server in Private DNS Zone
resource sqlPrivateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-11-01' = {
  parent: sqlPrivateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-database-windows-net'
        properties: {
          privateDnsZoneId: sqlPrivateDnsZone.id
        }
      }
    ]
  }
}

// =============================================================================
// Azure SQL Database (≈ AWS RDS Database)
// =============================================================================
resource sqlDb 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: sqlDbName
  location: location
  tags: {
    ArpioBackup: 'True'
  }
  sku: {
    name: 'Basic'                            // Cheapest tier ≈ db.t3.micro
    tier: 'Basic'
    capacity: 5
  }
}

// =============================================================================
// Cloud-init script (≈ EC2 User Data)
// Installs Apache, PHP, SQL Server drivers, Azure CLI, and deploys the app.
// Also downloads the Arpio logo and uploads it to Blob Storage.
// =============================================================================
var cloudInitScript = loadTextContent('cloud-init.yml')

// =============================================================================
// Application Gateway (≈ AWS Application Load Balancer)
// Layer 7 load balancer with WAF capabilities
// =============================================================================
resource appGateway 'Microsoft.Network/applicationGateways@2023-11-01' = {
  name: appGatewayName
  location: location
  tags: {
    ArpioBackup: 'True'
  }
  properties: {
    sku: {
      name: 'Standard_v2'
      tier: 'Standard_v2'
      capacity: 1
    }
    gatewayIPConfigurations: [
      {
        name: 'appGatewayIpConfig'
        properties: {
          subnet: {
            id: resourceId('Microsoft.Network/virtualNetworks/subnets', vnetName, appGatewaySubnetName)
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appGatewayFrontendIp'
        properties: {
          publicIPAddress: {
            id: appGatewayPublicIp.id
          }
        }
      }
    ]
    frontendPorts: [
      {
        name: 'port80'
        properties: {
          port: 80
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'appGatewayBackendPool'
        properties: {
          backendAddresses: [
            {
              ipAddress: nic.properties.ipConfigurations[0].properties.privateIPAddress
            }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'appGatewayBackendHttpSettings'
        properties: {
          port: 80
          protocol: 'Http'
          cookieBasedAffinity: 'Disabled'
          requestTimeout: 30
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', appGatewayName, 'appGatewayProbe')
          }
        }
      }
    ]
    httpListeners: [
      {
        name: 'appGatewayHttpListener'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', appGatewayName, 'appGatewayFrontendIp')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', appGatewayName, 'port80')
          }
          protocol: 'Http'
        }
      }
    ]
    requestRoutingRules: [
      {
        name: 'appGatewayRoutingRule'
        properties: {
          ruleType: 'Basic'
          priority: 100
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', appGatewayName, 'appGatewayHttpListener')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', appGatewayName, 'appGatewayBackendPool')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', appGatewayName, 'appGatewayBackendHttpSettings')
          }
        }
      }
    ]
    probes: [
      {
        name: 'appGatewayProbe'
        properties: {
          protocol: 'Http'
          path: '/'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: false
          host: nic.properties.ipConfigurations[0].properties.privateIPAddress
        }
      }
    ]
  }
}

// =============================================================================
// Load Balancer (≈ AWS Network Load Balancer)
// Layer 4 TCP/UDP load balancer
// =============================================================================
resource loadBalancer 'Microsoft.Network/loadBalancers@2023-11-01' = {
  name: loadBalancerName
  location: location
  tags: {
    ArpioBackup: 'True'
  }
  sku: {
    name: 'Standard'                         // Standard SKU required for cross-zone redundancy
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'loadBalancerFrontend'
        properties: {
          publicIPAddress: {
            id: loadBalancerPublicIp.id
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'loadBalancerBackendPool'
      }
    ]
    probes: [
      {
        name: 'httpProbe'
        properties: {
          protocol: 'Http'
          port: 80
          requestPath: '/'
          intervalInSeconds: 15
          numberOfProbes: 2
        }
      }
    ]
    loadBalancingRules: [
      {
        name: 'httpRule'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations', loadBalancerName, 'loadBalancerFrontend')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools', loadBalancerName, 'loadBalancerBackendPool')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes', loadBalancerName, 'httpProbe')
          }
          protocol: 'Tcp'
          frontendPort: 80
          backendPort: 80
          enableFloatingIP: false
          idleTimeoutInMinutes: 4
        }
      }
    ]
  }
}

// =============================================================================
// Outputs (≈ CloudFormation Outputs)
// =============================================================================

output vmPublicIp string = publicIp.properties.ipAddress
output vmSshCommand string = 'ssh ${vmAdminUsername}@${publicIp.properties.ipAddress}'
output webUrl string = 'http://${publicIp.properties.ipAddress}'
output appGatewayPublicIp string = appGatewayPublicIp.properties.ipAddress
output appGatewayUrl string = 'http://${appGatewayPublicIp.properties.ipAddress}'
output loadBalancerPublicIp string = loadBalancerPublicIp.properties.ipAddress
output loadBalancerUrl string = 'http://${loadBalancerPublicIp.properties.ipAddress}'
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName
output sqlDatabaseName string = sqlDbName
output keyVaultName string = keyVault.name
output keyVaultUri string = keyVault.properties.vaultUri
output storageAccountName string = storageAccount.name
output storageBlobEndpoint string = storageAccount.properties.primaryEndpoints.blob
output logoUrl string = '${storageAccount.properties.primaryEndpoints.blob}${blobContainerName}/arpio-logo.svg'
output resourceGroupName string = resourceGroup().name
output region string = location
