// =============================================================================
// SQL Database Module
// =============================================================================
// Creates an Azure SQL logical server + database with Azure AD-only
// authentication — no SQL login/password is ever created.
//
// Azure SQL supports only a single Azure AD admin *principal*, so the sole
// admin here is an Entra group (created in deploy-cluster.sh) containing both
// the deploying user and the app workload identity, rather than either one
// individually.
//
// For private-network: disables public access and provisions a private
// endpoint with private DNS zone integration into the cluster VNet.
// For other configs: allows Azure-hosted resources through the firewall.
// =============================================================================

@description('Name of the SQL logical server. Must be globally unique, lowercase.')
param sqlServerName string

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

@description('Object ID of the Entra group granted as the sole Azure AD admin.')
param aadAdminGroupId string

@description('Display name of the Entra group granted as the sole Azure AD admin.')
param aadAdminGroupName string

// ---------------------------------------------------------------------------
// SQL Server — Azure AD-only auth set inline at creation, so no SQL
// login/password is ever provisioned, not even transiently.
// ---------------------------------------------------------------------------

resource sqlServer 'Microsoft.Sql/servers@2023-08-01' = {
  name:     sqlServerName
  location: location
  properties: {
    version:             '12.0'
    publicNetworkAccess: isPrivateNetwork ? 'Disabled' : 'Enabled'
    administrators: {
      administratorType:        'ActiveDirectory'
      principalType:             'Group'
      login:                     aadAdminGroupName
      sid:                       aadAdminGroupId
      tenantId:                  subscription().tenantId
      azureADOnlyAuthentication: true
    }
  }
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01' = {
  parent:   sqlServer
  name:     databaseName
  location: location
  sku: {
    name:     'Basic'
    tier:     'Basic'
    capacity: 5
  }
}

// ---------------------------------------------------------------------------
// Firewall (non-private only) — admits Azure-hosted resources, not the
// whole internet.
// ---------------------------------------------------------------------------

resource allowAzureServices 'Microsoft.Sql/servers/firewallRules@2023-08-01' = if (!isPrivateNetwork) {
  parent: sqlServer
  name:   'AllowAzureServices'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress:   '0.0.0.0'
  }
}

// ---------------------------------------------------------------------------
// Private endpoint and DNS (private-network only)
// ---------------------------------------------------------------------------

resource sqlPrivateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = if (isPrivateNetwork) {
  name:     '${sqlServerName}-pe'
  location: location
  properties: {
    subnet: { id: subnetId }
    privateLinkServiceConnections: [
      {
        name: '${sqlServerName}-pe-conn'
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds:             ['sqlServer']
        }
      }
    ]
  }
}

resource sqlDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = if (isPrivateNetwork) {
  #disable-next-line no-hardcoded-env-urls
  name:     'privatelink.database.windows.net'
  location: 'global'
}

resource sqlDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = if (isPrivateNetwork) {
  parent:   sqlDnsZone
  name:     '${sqlServerName}-vnet-link'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: { id: vnetId }
  }
}

resource sqlDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (isPrivateNetwork) {
  parent: sqlPrivateEndpoint
  name:   'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'privatelink-database-windows-net'
        properties: {
          privateDnsZoneId: sqlDnsZone.id
        }
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output serverName   string = sqlServer.name
output serverFqdn   string = sqlServer.properties.fullyQualifiedDomainName
output databaseName string = sqlDatabase.name
