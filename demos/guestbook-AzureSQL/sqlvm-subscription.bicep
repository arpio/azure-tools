// get parameters
@description('Location for all resources.')
param location string

@description('resource group name (unique to the subscription)')
param resourceGroupName string

@description('Admin username for the VM')
param adminUsername string

@secure()
@description('Admin password for the VM')
param adminPassword string

@description('Admin username for SQL Server')
param sqlAdminUsername string

@secure()
@description('SQL Server admin password')
param sqlAdminPassword string

@description('Name of the VM')
param vmName string

@description('VM size')
param vmSize string

@description('SQL Server name (must be globally unique)')
param sqlServerName string

targetScope = 'subscription'

// create resource group
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
}

// Call resource group module with parameters
module rgContents 'sqlvm-rg.bicep' = {
  name: 'deploySqlVmRg'
  scope: rg
  params: {
    adminUsername: adminUsername
    adminPassword: adminPassword
    sqlAdminUsername: sqlAdminUsername
    sqlAdminPassword: sqlAdminPassword
    vmName: vmName
    vmSize: vmSize
    sqlServerName: sqlServerName
    sqlDatabaseName: 'GuestbookDb'
  }
}

// do role assignment
// Role Assignment - Key Vault Secrets User for VM
// use of resource group and VM name in place of their IDs isn't as unique but should still be ok
resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroupName, vmName, 'Key Vault Secrets User')
  properties: {
    principalId: rgContents.outputs.vmIdentityId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalType: 'ServicePrincipal'
  }
}

// return values
output publicIPAddress string = rgContents.outputs.publicIPAddress
output vmName string = rgContents.outputs.vmName
output vmIdentityId string = rgContents.outputs.vmIdentityId
output sqlServerFqdn string = rgContents.outputs.sqlServerFqdn
output keyVaultId string = rgContents.outputs.keyVaultId
output keyVaultName string = rgContents.outputs.keyVaultName
output rdpCommand string = 'mstsc /v:${rgContents.outputs.publicIPAddress}'
output sqlConnectionString string = rgContents.outputs.sqlConnectionString
