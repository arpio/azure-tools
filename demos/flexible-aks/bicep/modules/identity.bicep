// =============================================================================
// Managed Identity Module
// =============================================================================
// Creates a user-assigned managed identity for the AKS cluster.
// Role assignment (Managed Identity Operator to current user) is handled
// in deploy-cluster.sh via Azure CLI after this module runs.
// =============================================================================

@description('Name of the user-assigned managed identity.')
param identityName string

@description('Azure region.')
param location string = resourceGroup().location

// ---------------------------------------------------------------------------
// User-Assigned Managed Identity
// ---------------------------------------------------------------------------

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name:     identityName
  location: location
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output identityId          string = identity.id
output identityName        string = identity.name
output identityPrincipalId string = identity.properties.principalId
output identityClientId    string = identity.properties.clientId
