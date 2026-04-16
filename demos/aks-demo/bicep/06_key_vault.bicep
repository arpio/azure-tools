/*
  ============================================================================
  SECRETS MANAGEMENT – AZURE KEY VAULT + SECRETS STORE CSI DRIVER
  Logical order: 06
  ============================================================================
  Azure equivalent of the EKS demo's AWS Secrets Manager + Secrets Store CSI setup.

  AWS → Azure mapping
  ──────────────────────────────────────────────────────────────────────────
  AWS Secrets Manager                  → Azure Key Vault
  Secrets Store CSI Driver (Helm)      → Secrets Store CSI Driver (AKS add-on)
  AWS SM CSI Provider (DaemonSet)      → Azure Key Vault CSI Provider (AKS add-on)
  aws_secretsmanager_secret            → azurerm_key_vault_secret
  SecretProviderClass (provider: aws)  → SecretProviderClass (provider: azure)
  IRSA permissions for Secrets Manager → Workload Identity + Key Vault Secrets User role

  Key advantage over EKS demo:
  The Azure Key Vault CSI Provider is a managed AKS add-on. You don't need
  to manually deploy a DaemonSet like the EKS demo does for the AWS provider.
  The cluster extension handles everything.

  Architecture (same as EKS demo):
  1. Secret stored in Azure Key Vault
  2. AKS Key Vault CSI add-on (installed below)
  3. SecretProviderClass defines which secrets to fetch (applied in 05_application.sh)
  4. Pod mounts secrets as files via CSI volume
  ============================================================================
*/

// ── Parameters ───────────────────────────────────────────────────────────────

@description('Environment prefix.')
param prefixEnv string

@description('Azure region.')
param location string = resourceGroup().location

@description('Object ID of the identity running this deployment (for Key Vault admin access during deploy).')
param deployerObjectId string

@description('App managed identity principal ID (from 04_authentication.bicep).')
param appIdentityPrincipalId string

// ── Locals ────────────────────────────────────────────────────────────────────

// Key Vault names: globally unique, 3–24 chars, alphanumeric + hyphens only.
var shortEnv     = take(replace(prefixEnv, '-', ''), 16)
var kvName       = 'kv-${shortEnv}'
var secretName   = '${prefixEnv}-secret'

// ── Key Vault ─────────────────────────────────────────────────────────────────
/*
  Equivalent to aws_secretsmanager_secret in the EKS demo.
  enableRbacAuthorization = true uses Azure RBAC for access control
  (modern approach, replaces legacy access policies).
*/

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name:     kvName
  location: location
  properties: {
    tenantId:                 subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization:  true    // use Azure RBAC, not access policies
    softDeleteRetentionInDays: 7      // demo: 7 days; production: 90 days
    // enablePurgeProtection omitted — once set true it cannot be reverted, so
    // we leave it unset (defaults false on new vaults) to allow easy teardown.
  }
}

// ── Key Vault Secret ──────────────────────────────────────────────────────────
/*
  Equivalent to aws_secretsmanager_secret_version in the EKS demo.
  WARNING: In production, never hardcode real secrets in Bicep/Terraform!
  Use: az keyvault secret set --vault-name <kv> --name <name> --value <value>
  or an external secret management tool.
*/

// Grant the deployer Key Vault Secrets Officer so this Bicep can create secrets.
// (Only needed at deploy time – pods use a separate read-only role below.)
resource deployerKvSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name:  guid(keyVault.id, deployerObjectId, 'KeyVaultSecretsOfficer')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7') // Key Vault Secrets Officer
    principalId:      deployerObjectId
    principalType:    'User'
  }
}

resource kvSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name:   secretName
  // JSON format matches the EKS demo's jsonencode({ username = "admin", password = "..." })
  properties: {
    value: '{"username":"admin","password":"MySecurePassword123"}'
  }
  dependsOn: [deployerKvSecretsOfficer]
}

// ── Key Vault Secrets User role for the app identity ─────────────────────────
/*
  Grants the pod's Managed Identity read-only access to Key Vault secrets.
  Equivalent to:
    aws_iam_policy (secretsmanager:GetSecretValue, DescribeSecret)
    aws_iam_role_policy_attachment → ddb_access_role

  Key Vault Secrets User = read secret values, list secrets.
  Least privilege: cannot create, update, or delete secrets.
*/

resource appKvSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name:  guid(keyVault.id, appIdentityPrincipalId, 'KeyVaultSecretsUser')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6') // Key Vault Secrets User
    principalId:      appIdentityPrincipalId
    principalType:    'ServicePrincipal'
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

output keyVaultName  string = keyVault.name
output secretName    string = secretName
output tenantId      string = subscription().tenantId
