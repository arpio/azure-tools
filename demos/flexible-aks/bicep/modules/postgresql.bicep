// =============================================================================
// PostgreSQL Flexible Server Module
// =============================================================================
// Creates an Azure Database for PostgreSQL Flexible Server + database with
// Azure AD-only authentication — no server password is ever created.
//
// Unlike SQL, Postgres Flexible Server supports multiple independent Azure AD
// admins, so both the app workload identity and the deploying user are
// granted admin directly — no shared group needed here.
//
// For private-network: disables public access and provisions a private
// endpoint with private DNS zone integration into the cluster VNet, using
// Flexible Server's Private Link support (not VNet-integration/delegated
// subnet — keeps this consistent with how SQL/Cosmos/KV/ACR do private
// networking elsewhere in this demo).
// For other configs: allows Azure-hosted resources through the firewall.
// =============================================================================

@description('Name of the PostgreSQL Flexible Server. Must be globally unique, lowercase.')
param serverName string

@description('Name of the database to create.')
param databaseName string

@description('Azure region.')
param location string = resourceGroup().location

@description('Disable public access and create a private endpoint.')
param isPrivateNetwork bool = false

@description('Subnet resource ID for the private endpoint. Required when isPrivateNetwork is true.')
param subnetId string = ''

@description('VNet resource ID for the private DNS zone VNet link. Required when isPrivateNetwork is true.')
param vnetId string = ''

@description('Principal ID of the app workload identity. Granted as an Azure AD admin.')
param workloadIdentityPrincipalId string

@description('Name of the app workload identity, used as its admin display name.')
param workloadIdentityName string

@description('Object ID of the deploying user. Granted as an Azure AD admin.')
param deployingUserPrincipalId string

@description('UPN of the deploying user, used as their admin display name.')
param deployingUserUpn string

// ---------------------------------------------------------------------------
// Flexible Server — Azure AD-only auth, password auth disabled entirely.
// ---------------------------------------------------------------------------

resource postgresServer 'Microsoft.DBforPostgreSQL/flexibleServers@2023-06-01-preview' = {
  name:     serverName
  location: location
  sku: {
    name: 'Standard_B1ms'
    tier: 'Burstable'
  }
  properties: {
    version: '16'
    storage: {
      storageSizeGB: 32
    }
    network: {
      publicNetworkAccess: isPrivateNetwork ? 'Disabled' : 'Enabled'
    }
    authConfig: {
      activeDirectoryAuth: 'Enabled'
      passwordAuth:        'Disabled'
    }
  }
}

resource postgresDatabase 'Microsoft.DBforPostgreSQL/flexibleServers/databases@2023-06-01-preview' = {
  parent: postgresServer
  name:   databaseName
}

// ---------------------------------------------------------------------------
// Azure AD admins — workload identity and deploying user, each independent.
// ---------------------------------------------------------------------------

resource workloadIdentityAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2023-06-01-preview' = {
  parent: postgresServer
  name:   workloadIdentityPrincipalId
  properties: {
    principalType: 'ServicePrincipal'
    principalName: workloadIdentityName
    tenantId:      subscription().tenantId
  }
}

resource deployingUserAdmin 'Microsoft.DBforPostgreSQL/flexibleServers/administrators@2023-06-01-preview' = {
  parent: postgresServer
  name:   deployingUserPrincipalId
  properties: {
    principalType: 'User'
    principalName: deployingUserUpn
    tenantId:      subscription().tenantId
  }
}

// ---------------------------------------------------------------------------
// Firewall (non-private only) — admits Azure-hosted resources, not the
// whole internet.
// ---------------------------------------------------------------------------

resource allowAzureServices 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2023-06-01-preview' = if (!isPrivateNetwork) {
  parent: postgresServer
  name:   'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress:   '0.0.0.0'
  }
}

// ---------------------------------------------------------------------------
// Private endpoint and DNS (private-network only)
// ---------------------------------------------------------------------------

resource postgresPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (isPrivateNetwork) {
  name:     '${serverName}-pe'
  location: location
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: '${serverName}-pe-conn'
        properties: {
          privateLinkServiceId: postgresServer.id
          groupIds:             ['postgresqlServer']
        }
      }
    ]
  }
}

resource postgresDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (isPrivateNetwork) {
  name:     'privatelink.postgres.database.azure.com'
  location: 'global'
}

resource postgresDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (isPrivateNetwork) {
  parent:   postgresDnsZone
  name:     '${serverName}-vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}

resource postgresDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (isPrivateNetwork) {
  parent: postgresPrivateEndpoint
  name:   'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-postgres-database-azure-com'
        properties: {
          privateDnsZoneId: postgresDnsZone.id
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output serverName   string = postgresServer.name
output serverFqdn   string = postgresServer.properties.fullyQualifiedDomainName
output databaseName string = postgresDatabase.name
