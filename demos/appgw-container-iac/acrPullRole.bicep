// ============================================================================
// AcrPull Role Assignment (cross-resource-group module)
//
// This is a separate Bicep module because the ACR lives in a different
// resource group than the main deployment. Bicep requires a module to
// create resources in a different scope.
//
// Called from azuredeploy.bicep with:
//   scope: resourceGroup(acrResourceGroup)
// ============================================================================

@description('Name of the existing Azure Container Registry')
param acrName string

@description('Principal ID of the managed identity to grant AcrPull')
param principalId string

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

// AcrPull allows the identity to pull container images from this registry.
// This is used instead of admin credentials — more secure and works better
// with Arpio DR (identity + role assignment are recovered, no passwords to update).
resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, principalId, 'AcrPull')
  scope: acr
  properties: {
    // AcrPull: 7f951dda-4ed3-4680-a7ca-43fe172d538d
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
