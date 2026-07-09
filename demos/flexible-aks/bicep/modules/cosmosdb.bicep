// =============================================================================
// Cosmos DB Module
// =============================================================================
// Creates a Cosmos DB account (SQL/Core API, serverless) + database +
// container. Cosmos has no "admin" concept the way SQL/Postgres do — data
// access is granted via Cosmos DB's own RBAC role assignments, not
// Microsoft.Authorization. Both the app workload identity and the deploying
// user are granted the built-in Data Contributor role (the closest Cosmos
// equivalent to "admin"). Key-based (local) auth is disabled entirely.
//
// For private-network: disables public access and provisions a private
// endpoint with private DNS zone integration into the cluster VNet.
// =============================================================================

@description('Name of the Cosmos DB account. Globally unique, lowercase.')
param accountName string

@description('Name of the SQL API database and container to create.')
param databaseName string

@description('Azure region.')
param location string = resourceGroup().location

@description('Disable public access and create a private endpoint.')
param isPrivateNetwork bool = false

@description('Subnet resource ID for the private endpoint. Required when isPrivateNetwork is true.')
param subnetId string = ''

@description('VNet resource ID for the private DNS zone VNet link. Required when isPrivateNetwork is true.')
param vnetId string = ''

@description('Principal ID of the app workload identity. Granted the Data Contributor role.')
param workloadIdentityPrincipalId string

@description('Object ID of the deploying user. Granted the Data Contributor role.')
param deployingUserPrincipalId string

// ---------------------------------------------------------------------------
// Cosmos DB Account — SQL (Core) API, serverless, key-based auth disabled.
// ---------------------------------------------------------------------------

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name:     accountName
  location: location
  kind:     'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [
      {
        locationName:     location
        failoverPriority: 0
      }
    ]
    capabilities: [
      { name: 'EnableServerless' }
    ]
    disableLocalAuth:    true
    publicNetworkAccess: isPrivateNetwork ? 'Disabled' : 'Enabled'
  }
}

resource cosmosDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  parent: cosmosAccount
  name:   databaseName
  properties: {
    resource: { id: databaseName }
  }
}

resource cosmosContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: cosmosDatabase
  name:   databaseName
  properties: {
    resource: {
      id: databaseName
      partitionKey: {
        paths: ['/id']
        kind:  'Hash'
      }
    }
  }
}

// ---------------------------------------------------------------------------
// RBAC: workload identity and deploying user -> Cosmos DB Built-in Data
// Contributor. Cosmos role assignments/definitions are scoped under the
// account rather than via Microsoft.Authorization.
// ---------------------------------------------------------------------------

var dataContributorRoleId = resourceId(
  'Microsoft.DocumentDB/databaseAccounts/sqlRoleDefinitions',
  cosmosAccount.name,
  '00000000-0000-0000-0000-000000000002'
)

resource workloadIdentityRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = {
  parent: cosmosAccount
  name:   guid(cosmosAccount.id, workloadIdentityPrincipalId, 'cosmos-data-contributor')
  properties: {
    roleDefinitionId: dataContributorRoleId
    principalId:      workloadIdentityPrincipalId
    scope:            cosmosAccount.id
  }
}

resource deployingUserRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = {
  parent: cosmosAccount
  name:   guid(cosmosAccount.id, deployingUserPrincipalId, 'cosmos-data-contributor')
  properties: {
    roleDefinitionId: dataContributorRoleId
    principalId:      deployingUserPrincipalId
    scope:            cosmosAccount.id
  }
}

// ---------------------------------------------------------------------------
// Private endpoint and DNS (private-network only)
// ---------------------------------------------------------------------------

resource cosmosPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (isPrivateNetwork) {
  name:     '${accountName}-pe'
  location: location
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: '${accountName}-pe-conn'
        properties: {
          privateLinkServiceId: cosmosAccount.id
          groupIds:             ['Sql']
        }
      }
    ]
  }
}

resource cosmosDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (isPrivateNetwork) {
  name:     'privatelink.documents.azure.com'
  location: 'global'
}

resource cosmosDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (isPrivateNetwork) {
  parent:   cosmosDnsZone
  name:     '${accountName}-vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}

resource cosmosDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (isPrivateNetwork) {
  parent: cosmosPrivateEndpoint
  name:   'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-documents-azure-com'
        properties: {
          privateDnsZoneId: cosmosDnsZone.id
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output accountName  string = cosmosAccount.name
output endpoint      string = cosmosAccount.properties.documentEndpoint
output databaseName string = cosmosDatabase.name
