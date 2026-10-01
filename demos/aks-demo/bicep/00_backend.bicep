/*
  ============================================================================
  BACKEND STORAGE
  Logical order: 00 (bootstraps before all other steps)
  ============================================================================
  Creates the Azure Blob Storage account used for tracking Bicep deployments.
  Equivalent to the S3 + DynamoDB backend in the EKS demo's Terraform setup.

  The storage account name is derived from uniqueString(resourceGroup().id),
  which produces a deterministic 13-char hash — same result on every run,
  globally unique per resource group.
  ============================================================================
*/

param location string = resourceGroup().location

// 'bicepstate' (10) + uniqueString (13) = 23 chars — within the 24-char limit.
// uniqueString() already returns lowercase alphanumeric, no hyphens needed.
var storageAccountName = 'bicepstate${uniqueString(resourceGroup().id)}'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: storageAccountName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: storageAccount
  name: 'default'
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: 'bicep-state'
}

output storageAccountName string = storageAccount.name
