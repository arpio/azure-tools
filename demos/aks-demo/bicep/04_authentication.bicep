/*
  ============================================================================
  AZURE WORKLOAD IDENTITY (equivalent to EKS IRSA)
  Logical order: 04
  ============================================================================
  Azure Workload Identity is the Azure equivalent of EKS IRSA
  (IAM Roles for Service Accounts).

  AWS → Azure mapping
  ──────────────────────────────────────────────────────────────────────────
  OIDC Identity Provider        → AKS OIDC Issuer (oidcIssuerProfile.enabled)
  IAM Role + trust policy       → User-Assigned Managed Identity
                                   + Federated Identity Credential
  K8s ServiceAccount annotation → same annotation pattern (different key)
  sts:AssumeRoleWithWebIdentity → Azure AD OIDC token exchange

  How Workload Identity works (mirrors IRSA flow exactly):
  1. AKS cluster has an OIDC issuer URL  (enabled in 01_infrastructure.bicep)
  2. Create a User-Assigned Managed Identity in Azure AD
  3. Create a Federated Identity Credential linking the identity to a specific
     Kubernetes ServiceAccount in a specific namespace  ← equivalent to the
     IAM trust policy StringEquals condition in the EKS demo
  4. Annotate the K8s ServiceAccount with the managed identity client ID
  5. Pods using that ServiceAccount get Azure credentials injected automatically
  6. Azure SDKs use DefaultAzureCredential() to pick them up – no code changes

  The magic: Azure AD validates pod identity via OIDC token exchange before
  issuing credentials — same STS + OIDC mechanism as AWS IRSA.
  ============================================================================
*/

// ── Parameters ───────────────────────────────────────────────────────────────

@description('Environment prefix (output from 01_infrastructure.bicep).')
param prefixEnv string

@description('Azure region.')
param location string = resourceGroup().location

@description('OIDC issuer URL of the AKS cluster (output from 01_infrastructure.bicep).')
param oidcIssuerUrl string

@description('Cosmos DB account resource ID (for role assignment scope).')
param cosmosAccountId string

@description('Cosmos DB account name.')
param cosmosAccountName string

// ── App Managed Identity ──────────────────────────────────────────────────────
/*
  This identity is assumed by pods running the guestbook app.
  Equivalent to aws_iam_role.ddb_access_role in the EKS demo.
*/

resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name:     '${prefixEnv}-app-identity'
  location: location
}

// ── Federated Identity Credential ────────────────────────────────────────────
/*
  Links the managed identity to a specific Kubernetes ServiceAccount.
  Equivalent to the IAM trust policy with these StringEquals conditions:
    "${oidc}:sub" = "system:serviceaccount:default:cosmos-<env>-sa"
    "${oidc}:aud" = "sts.amazonaws.com"

  This prevents other pods (or other namespaces) from using this identity.
  subject must exactly match: system:serviceaccount:<namespace>:<sa-name>
*/

var serviceAccountName = 'cosmos-${prefixEnv}-sa'

resource federatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: appIdentity
  name:   '${prefixEnv}-app-fedcred'
  properties: {
    issuer:   oidcIssuerUrl                                      // AKS OIDC issuer
    subject:  'system:serviceaccount:default:${serviceAccountName}' // which K8s SA can use this identity
    audiences: ['api://AzureADTokenExchange']                   // standard audience for Workload Identity
  }
}

// ── Cosmos DB RBAC ────────────────────────────────────────────────────────────
/*
  Grant the app identity read/write permission on Cosmos DB data.
  Equivalent to attaching AmazonDynamoDBFullAccess to the IRSA role in the EKS demo.

  "Cosmos DB Built-in Data Contributor" (00000000-…-0002) = full read/write on
  data plane only – not the management plane. This is least-privilege compared
  to the EKS demo's DynamoDBFullAccess, but functionally equivalent for the app.
*/

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-02-15-preview' existing = {
  name: cosmosAccountName
}

resource cosmosDataContributor 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2021-10-15' = {
  parent: cosmosAccount
  name:   guid(cosmosAccountId, appIdentity.id, 'CosmosDataContributor')
  properties: {
    // Built-in "Cosmos DB Built-in Data Contributor" role definition ID
    roleDefinitionId: '${cosmosAccountId}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002'
    principalId:      appIdentity.properties.principalId
    scope:            cosmosAccountId
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

output appIdentityClientId    string = appIdentity.properties.clientId
output appIdentityPrincipalId string = appIdentity.properties.principalId
output serviceAccountName     string = serviceAccountName
