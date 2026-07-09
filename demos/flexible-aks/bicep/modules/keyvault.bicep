// =============================================================================
// Key Vault Module
// =============================================================================
// Creates an Azure Key Vault in the cluster resource group with RBAC
// authorization. Grants:
//   Key Vault Secrets User  → cluster managed identity (system or user-assigned)
//   Key Vault Administrator → deploying user
//
// For private-network: disables public access and provisions a private
// endpoint with private DNS zone integration into the cluster VNet.
// =============================================================================

@description('Name of the Key Vault. Max 24 chars, must start with a letter.')
param kvName string

@description('Azure region.')
param location string = resourceGroup().location

@description('Disable public network access and create a private endpoint.')
param isPrivateNetwork bool = false

@description('VNet resource ID for the private DNS zone VNet link. Required when isPrivateNetwork is true.')
param vnetId string = ''

@description('Subnet resource ID for the private endpoint. Required when isPrivateNetwork is true.')
param subnetId string = ''

@description('Principal ID of the AKS cluster managed identity. Granted Key Vault Secrets User.')
param clusterPrincipalId string

@description('Object ID of the deploying user. Granted Key Vault Administrator.')
param deployingUserPrincipalId string

// ---------------------------------------------------------------------------
// Key Vault
// ---------------------------------------------------------------------------

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name:     kvName
  location: location
  properties: {
    sku: {
      family: 'A'
      name:   'standard'
    }
    tenantId:              subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete:      true
    softDeleteRetentionInDays: 7
    publicNetworkAccess:   isPrivateNetwork ? 'Disabled' : 'Enabled'
    networkAcls: {
      bypass:        'AzureServices'
      defaultAction: isPrivateNetwork ? 'Deny' : 'Allow'
    }
  }
}

// ---------------------------------------------------------------------------
// RBAC: cluster identity → Key Vault Secrets User
// ---------------------------------------------------------------------------

resource secretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name:  guid(kv.id, clusterPrincipalId, 'kv-secrets-user')
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    )
    principalId:   clusterPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// RBAC: deploying user → Key Vault Administrator
// ---------------------------------------------------------------------------

resource adminAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name:  guid(kv.id, deployingUserPrincipalId, 'kv-admin')
  scope: kv
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '00482a5a-887f-4fb3-b363-3b7fe8e74483'
    )
    principalId:   deployingUserPrincipalId
    principalType: 'User'
  }
}

// ---------------------------------------------------------------------------
// Private endpoint and DNS (private-network only)
// ---------------------------------------------------------------------------

// Both kvPrivateEndpoint and its child kvDnsZoneGroup use if (isPrivateNetwork);
// Bicep allows a conditional child to reference a conditional parent when the
// condition expression is identical.

resource kvPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (isPrivateNetwork) {
  name:     '${kvName}-pe'
  location: location
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: '${kvName}-pe-conn'
        properties: {
          privateLinkServiceId: kv.id
          groupIds:             ['vault']
        }
      }
    ]
  }
}

resource kvDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (isPrivateNetwork) {
  name:     'privatelink.vaultcore.azure.net'
  location: 'global'
}

resource kvDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (isPrivateNetwork) {
  parent:   kvDnsZone
  name:     '${kvName}-vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}

resource kvDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (isPrivateNetwork) {
  parent: kvPrivateEndpoint
  name:   'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-vaultcore-azure-net'
        properties: {
          privateDnsZoneId: kvDnsZone.id
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output kvName string = kv.name
output kvUri  string = kv.properties.vaultUri
