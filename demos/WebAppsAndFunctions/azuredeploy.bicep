// ============================================================================
// Web App + Function App + Container App + Key Vault Demo (Arpio Demo 05)
//
// Deploys: App Service (Flask) + Function App (Status API) + Key Vault
//          + Blob Storage (Arpio logo) with region-aware Key Vault secrets
//
// Traffic flow:
//   Internet → Web App (public URL, port 443)
//            → Function App /api/status (HTTPS call from Web App)
//            → Key Vault (RBAC, managed identity)
//
// App code is embedded via loadTextContent() and deployed to Kudu by
// deployment script resources — single `az deployment group create` does everything.
// ============================================================================

// ---------- Parameters ----------

@description('Azure region for all resources')
param location string

@description('Base name used to derive resource names')
param baseName string = 'webapp-func'

// ---------- Variables ----------

// Deterministic unique suffix derived from subscription + resource group + deployment name.
// Used to generate globally unique names for storage accounts, key vaults, and web apps.
var uniqueSuffix = uniqueString(subscription().id, resourceGroup().id, deployment().name)

// Resource name prefix for easy identification in the Azure portal and Arpio.
// "wad05" = Web App Demo 05.
var prefix = 'wad05'

var managedIdName = '${prefix}-id-${baseName}'
var kvName = '${prefix}-kv-${uniqueSuffix}'
var funcStorageAccountName = toLower('${prefix}st${uniqueSuffix}')
var blobStorageAccountName = toLower('${prefix}bl${uniqueSuffix}')
var blobContainerName = 'assets'
var appServicePlanName = '${prefix}-plan-${baseName}'
var webAppName = '${prefix}-web-${baseName}-${uniqueSuffix}'
var functionPlanName = '${prefix}-plan-func-${baseName}'
var functionAppName = '${prefix}-func-${baseName}-${uniqueSuffix}'
var logAnalyticsName = '${prefix}-logs-${baseName}'
var containerEnvName = '${prefix}-cae-${baseName}'
var containerAppName = '${prefix}-worker-${baseName}'

// ---------- App Code (embedded via loadTextContent) ----------
// Loaded at compile time and passed to deployment scripts that push code to Kudu.
// Changing any file automatically triggers redeployment via codeHash.

var webAppPy = loadTextContent('webapp/app.py')
var webAppRequirements = loadTextContent('webapp/requirements.txt')
var webAppStartup = loadTextContent('webapp/startup.sh')
var functionInitPy = loadTextContent('function-app/status/__init__.py')
var functionJsonContent = loadTextContent('function-app/status/function.json')
var functionHostJson = loadTextContent('function-app/host.json')
var functionRequirements = loadTextContent('function-app/requirements.txt')
var logoSvg = loadTextContent('assets/arpio-logo.svg')
var faviconBase64 = loadFileAsBase64('assets/arpio-favicon.png')

// Hash of all app code + assets — forces deployment script re-run when any of these change.
var codeHash = uniqueString(webAppPy, webAppRequirements, functionInitPy, functionJsonContent, functionHostJson, logoSvg, faviconBase64)

// Common tags applied to all resources
var commonTags = {
  ArpioDemo05: 'True'
  Environment: 'Demo'
  ManagedBy: 'Bicep'
}

// ============================================================================
// MANAGED IDENTITY
// A single user-assigned identity shared by both the Web App and Function App
// for Key Vault access via RBAC.
// ============================================================================

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: managedIdName
  location: location
  tags: commonTags
}

// ============================================================================
// KEY VAULT
// Stores a demo secret. Uses RBAC authorization (no access policies).
// Both the Web App and Function App read secrets via managed identity.
// ============================================================================

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  tags: commonTags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource demoSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'demo-secret'
  tags: commonTags
  properties: {
    value: 'Hello from Arpio Demo 05! This secret was created at deployment time.'
  }
}

// Region identifier — stored as an ARM location resource ID so Arpio can
// recognize and translate it during DR failover to the recovery region.
// Format: /subscriptions/{sub}/providers/Microsoft.Resources/locations/{region}
resource regionSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'app-region'
  tags: commonTags
  properties: {
    value: '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Resources/locations/${location}'
  }
}

// Blob storage endpoint — Arpio translates this URL during DR failover
// to point to the recovered storage account in the new region.
resource storageBlobUrlSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'storage-blob-url'
  tags: commonTags
  properties: {
    value: blobStorageAccount.properties.primaryEndpoints.blob
  }
}

// Key Vault Secrets User role assignment for the managed identity
// Role ID: 4633458b-17de-408a-b874-0445c86b69e6 (Key Vault Secrets User)
resource kvRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, managedIdentity.id, 'Key Vault Secrets User')
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// STORAGE ACCOUNT (Function App)
// Required by the Function App runtime for triggers, bindings, and state.
// Public blob access is disabled — this account is internal to the Function App.
// ============================================================================

resource funcStorageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: funcStorageAccountName
  location: location
  tags: commonTags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

// Enable Change Feed + Versioning — required by Arpio for blob replication during DR backup.
resource funcBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: funcStorageAccount
  name: 'default'
  properties: {
    changeFeed: {
      enabled: true
    }
    isVersioningEnabled: true
  }
}

// ============================================================================
// STORAGE ACCOUNT (Blob — public assets)
// Hosts the Arpio logo and static assets. Public blob access is enabled so
// the Web App can display the logo via <img> tag. The blob endpoint URL is
// stored in Key Vault so Arpio can translate it during DR failover.
// ============================================================================

resource blobStorageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: blobStorageAccountName
  location: location
  tags: commonTags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: true
  }
}

// Enable Change Feed + Versioning — required by Arpio for blob replication during DR backup.
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-01-01' = {
  parent: blobStorageAccount
  name: 'default'
  properties: {
    changeFeed: {
      enabled: true
    }
    isVersioningEnabled: true
  }
}

resource blobContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-01-01' = {
  parent: blobService
  name: blobContainerName
  properties: {
    publicAccess: 'Blob'
  }
}

// ============================================================================
// APP SERVICE PLAN (Web App)
// Basic B1 tier, Linux, for the Flask dashboard.
// ============================================================================

resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  tags: commonTags
  kind: 'linux'
  sku: {
    name: 'B1'
    tier: 'Basic'
  }
  properties: {
    reserved: true // Required for Linux
  }
}

// ============================================================================
// WEB APP
// Python 3.11 Flask app serving the dashboard. Calls the Function App's
// /api/status endpoint and reads secrets from Key Vault.
// ============================================================================

resource webApp 'Microsoft.Web/sites@2023-12-01' = {
  name: webAppName
  location: location
  tags: commonTags
  kind: 'app,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.12'
      appCommandLine: 'gunicorn --bind=0.0.0.0:8000 app:app'
      alwaysOn: true
      appSettings: [
        { name: 'KEY_VAULT_URL', value: keyVault.properties.vaultUri }
        { name: 'FUNCTION_APP_URL', value: 'https://${functionApp.properties.defaultHostName}' }
        { name: 'STORAGE_BLOB_URL', value: blobStorageAccount.properties.primaryEndpoints.blob }
        { name: 'AZURE_CLIENT_ID', value: managedIdentity.properties.clientId }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'false' }
        { name: 'PYTHONPATH', value: '/home/site/wwwroot/.python_packages/lib/site-packages' }
        // Container App identifiers — the dashboard reads the worker's live
        // config from the Azure Resource Manager API using the managed identity.
        { name: 'CONTAINER_APP_ID', value: containerApp.id }
        { name: 'CONTAINER_APP_NAME', value: containerApp.name }
      ]
    }
    httpsOnly: true
  }
}

// ============================================================================
// APP SERVICE PLAN (Function App)
// Basic B1 tier, Linux. Using dedicated plan instead of Consumption (Y1)
// because Azure does not allow mixing Dynamic and Basic Linux plans in the
// same resource group.
// ============================================================================

resource functionPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: functionPlanName
  location: location
  tags: commonTags
  kind: 'linux'
  sku: {
    name: 'B1'
    tier: 'Basic'
  }
  properties: {
    reserved: true
  }
}

// ============================================================================
// FUNCTION APP
// Python 3.12 (Linux), HTTP-triggered status API. Returns JSON with hostname,
// runtime info, Key Vault connectivity, and Arpio tags.
// Uses appCommandLine to verify Arpio preserves siteConfig during recovery.
// ============================================================================

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  tags: commonTags
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: functionPlan.id
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.12'
      appCommandLine: 'python -m azure.functions'
      alwaysOn: true
      appSettings: [
        { name: 'AzureWebJobsStorage', value: 'DefaultEndpointsProtocol=https;AccountName=${funcStorageAccount.name};EndpointSuffix=${environment().suffixes.storage};AccountKey=${funcStorageAccount.listKeys().keys[0].value}' }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'python' }
        { name: 'KEY_VAULT_URL', value: keyVault.properties.vaultUri }
        { name: 'AZURE_CLIENT_ID', value: managedIdentity.properties.clientId }
        { name: 'PYTHONPATH', value: '/home/site/wwwroot/.python_packages/lib/site-packages' }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'false' }
        { name: 'ENABLE_ORYX_BUILD', value: 'false' }
      ]
    }
    httpsOnly: true
  }
}

// ============================================================================
// DEPLOYMENT IDENTITY
// Used by the deployment scripts to push app code to Kudu.
// Needs Website Contributor role to retrieve publishing credentials.
// ============================================================================

resource deployIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${prefix}-id-deploy-${baseName}'
  location: location
  tags: commonTags
}

// Website Contributor role (de139f84-1756-47ae-9be6-808fbbe84772) on the resource group
resource deployRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, deployIdentity.id, 'Website Contributor')
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'de139f84-1756-47ae-9be6-808fbbe84772')
    principalId: deployIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Also grant Storage Blob Data Contributor for uploading the logo to blob storage
resource deployStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(blobStorageAccount.id, deployIdentity.id, 'Storage Blob Data Contributor')
  scope: blobStorageAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: deployIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ============================================================================
// DEPLOYMENT SCRIPT: Upload logo to blob storage
// Uploads the Arpio logo SVG to the public assets container.
// ============================================================================

resource uploadAssets 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: '${prefix}-upload-assets'
  location: location
  tags: commonTags
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${deployIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.50.0'
    retentionInterval: 'PT1H'
    timeout: 'PT5M'
    forceUpdateTag: codeHash
    environmentVariables: [
      { name: 'STORAGE_ACCOUNT', value: blobStorageAccount.name }
      { name: 'CONTAINER_NAME', value: blobContainerName }
      { name: 'LOGO_CONTENT', value: logoSvg }
      { name: 'FAVICON_BASE64', value: faviconBase64 }
    ]
    scriptContent: '''
      set -e
      # --- Logo (SVG text) ---
      echo "$LOGO_CONTENT" > /tmp/arpio-logo.svg
      az storage blob upload \
        --account-name "$STORAGE_ACCOUNT" \
        --container-name "$CONTAINER_NAME" \
        --name arpio-logo.svg \
        --file /tmp/arpio-logo.svg \
        --content-type "image/svg+xml" \
        --overwrite true \
        --auth-mode login \
        -o none
      echo "Uploaded: $STORAGE_ACCOUNT/$CONTAINER_NAME/arpio-logo.svg"

      # --- Favicon (binary PNG passed as base64) ---
      echo "$FAVICON_BASE64" | base64 -d > /tmp/arpio-favicon.png
      az storage blob upload \
        --account-name "$STORAGE_ACCOUNT" \
        --container-name "$CONTAINER_NAME" \
        --name arpio-favicon.png \
        --file /tmp/arpio-favicon.png \
        --content-type "image/png" \
        --overwrite true \
        --auth-mode login \
        -o none
      echo "Uploaded: $STORAGE_ACCOUNT/$CONTAINER_NAME/arpio-favicon.png"
    '''
  }
  dependsOn: [
    blobContainer
    deployStorageRoleAssignment
  ]
}

// ============================================================================
// DEPLOYMENT SCRIPT: Deploy Web App code
// Bundles app.py + requirements.txt + pip dependencies into a zip and pushes
// it to the Web App filesystem via Kudu /api/zip/site/wwwroot/.
// ============================================================================

resource deployWebAppCode 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: '${prefix}-deploy-webapp'
  location: location
  tags: commonTags
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${deployIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.50.0'
    retentionInterval: 'PT1H'
    timeout: 'PT15M'
    forceUpdateTag: codeHash
    environmentVariables: [
      { name: 'APP_NAME', value: webApp.name }
      { name: 'RG', value: resourceGroup().name }
      { name: 'APP_PY', value: webAppPy }
      { name: 'REQUIREMENTS', value: webAppRequirements }
      { name: 'STARTUP_SH', value: webAppStartup }
    ]
    scriptContent: '''
      set -e
      echo "=== Deploying Web App code ==="

      # Write app files
      mkdir -p /tmp/deploy
      echo "$APP_PY" > /tmp/deploy/app.py
      echo "$REQUIREMENTS" > /tmp/deploy/requirements.txt
      echo "$STARTUP_SH" > /tmp/deploy/startup.sh
      chmod +x /tmp/deploy/startup.sh

      # Install dependencies for Linux x86_64
      pip install \
        --target /tmp/deploy/.python_packages/lib/site-packages \
        --platform manylinux2014_x86_64 \
        --only-binary=:all: \
        --python-version 3.12 \
        -r /tmp/deploy/requirements.txt \
        --quiet

      # Create zip
      cd /tmp/deploy
      zip -r -q /tmp/webapp.zip .

      # Get publishing credentials
      CREDS=$(az webapp deployment list-publishing-credentials \
        --resource-group "$RG" --name "$APP_NAME" -o json)
      USER=$(echo "$CREDS" | python3 -c "import sys,json;print(json.load(sys.stdin)['publishingUserName'])")
      PASS=$(echo "$CREDS" | python3 -c "import sys,json;print(json.load(sys.stdin)['publishingPassword'])")

      # Deploy with retry (SCM site may need time to warm up)
      for i in 1 2 3 4 5; do
        HTTP=$(curl -s --max-time 300 -X PUT \
          -u "$USER:$PASS" \
          --data-binary @/tmp/webapp.zip \
          -H "Content-Type: application/zip" \
          "https://${APP_NAME}.scm.azurewebsites.net/api/zip/site/wwwroot/" \
          -o /dev/null -w "%{http_code}")
        echo "Attempt $i: HTTP $HTTP"
        [ "$HTTP" = "200" ] && break
        echo "Retrying in 30s..."
        sleep 30
      done

      [ "$HTTP" = "200" ] && echo "Web App deployed!" || { echo "ERROR: Deploy failed"; exit 1; }
    '''
  }
  dependsOn: [
    deployRoleAssignment
  ]
}

// ============================================================================
// DEPLOYMENT SCRIPT: Deploy Function App code
// Bundles status/__init__.py + function.json + host.json + pip dependencies
// into a zip and pushes it to the Function App filesystem via Kudu.
// ============================================================================

resource deployFunctionAppCode 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: '${prefix}-deploy-functionapp'
  location: location
  tags: commonTags
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${deployIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.50.0'
    retentionInterval: 'PT1H'
    timeout: 'PT15M'
    forceUpdateTag: codeHash
    environmentVariables: [
      { name: 'APP_NAME', value: functionApp.name }
      { name: 'RG', value: resourceGroup().name }
      { name: 'FUNCTION_INIT_PY', value: functionInitPy }
      { name: 'FUNCTION_JSON', value: functionJsonContent }
      { name: 'HOST_JSON', value: functionHostJson }
      { name: 'REQUIREMENTS', value: functionRequirements }
    ]
    scriptContent: '''
      set -e
      echo "=== Deploying Function App code (Python / Linux) ==="

      # Write function files (v1 model: status/ folder with __init__.py + function.json)
      mkdir -p /tmp/deploy/status
      echo "$FUNCTION_INIT_PY" > /tmp/deploy/status/__init__.py
      echo "$FUNCTION_JSON" > /tmp/deploy/status/function.json
      echo "$HOST_JSON" > /tmp/deploy/host.json
      echo "$REQUIREMENTS" > /tmp/deploy/requirements.txt

      # Install dependencies for Linux x86_64
      pip install \
        --target /tmp/deploy/.python_packages/lib/site-packages \
        --platform manylinux2014_x86_64 \
        --only-binary=:all: \
        --python-version 3.12 \
        -r /tmp/deploy/requirements.txt \
        --quiet

      # Create zip
      cd /tmp/deploy
      zip -r -q /tmp/funcapp.zip .

      # Get publishing credentials
      CREDS=$(az webapp deployment list-publishing-credentials \
        --resource-group "$RG" --name "$APP_NAME" -o json)
      USER=$(echo "$CREDS" | python3 -c "import sys,json;print(json.load(sys.stdin)['publishingUserName'])")
      PASS=$(echo "$CREDS" | python3 -c "import sys,json;print(json.load(sys.stdin)['publishingPassword'])")

      # Deploy with retry (SCM site may need time to warm up)
      for i in 1 2 3 4 5; do
        HTTP=$(curl -s --max-time 300 -X PUT \
          -u "$USER:$PASS" \
          --data-binary @/tmp/funcapp.zip \
          -H "Content-Type: application/zip" \
          "https://${APP_NAME}.scm.azurewebsites.net/api/zip/site/wwwroot/" \
          -o /dev/null -w "%{http_code}")
        echo "Attempt $i: HTTP $HTTP"
        [ "$HTTP" = "200" ] && break
        echo "Retrying in 30s..."
        sleep 30
      done

      [ "$HTTP" = "200" ] && echo "Function App deployed!" || { echo "ERROR: Deploy failed"; exit 1; }
    '''
  }
  dependsOn: [
    deployRoleAssignment
  ]
}

// ============================================================================
// LOG ANALYTICS WORKSPACE
// Required by the Container Apps Environment for application logging.
// ============================================================================

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsName
  location: location
  tags: commonTags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// ============================================================================
// CONTAINER APPS ENVIRONMENT
// The hosting boundary for the Container App. Sends logs to Log Analytics.
// ============================================================================

resource containerEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: containerEnvName
  location: location
  tags: commonTags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
  }
}

// ============================================================================
// CONTAINER APP (Background Worker)
// A background worker using a public sample image (no HTTP ingress). Runs a
// heartbeat loop. Its environment variables are its "configuration" — the
// Web App dashboard reads them live from the Azure Resource Manager API.
// ============================================================================

resource containerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: containerAppName
  location: location
  tags: commonTags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    managedEnvironmentId: containerEnv.id
    configuration: {
      // No ingress — this is a background worker, not an HTTP service.
      activeRevisionsMode: 'Single'
    }
    template: {
      containers: [
        {
          name: 'worker'
          image: 'mcr.microsoft.com/cbl-mariner/busybox:2.0'
          command: [
            '/bin/sh'
          ]
          args: [
            '-c'
            'while true; do echo "[heartbeat] ArpioDemo05 background worker running at $(date -u)"; sleep 30; done'
          ]
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: [
            { name: 'WORKER_NAME', value: 'ArpioDemo05-Worker' }
            { name: 'KEY_VAULT_URL', value: keyVault.properties.vaultUri }
            { name: 'APP_REGION', value: '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Resources/locations/${location}' }
            { name: 'STORAGE_BLOB_URL', value: blobStorageAccount.properties.primaryEndpoints.blob }
            { name: 'AZURE_CLIENT_ID', value: managedIdentity.properties.clientId }
          ]
        }
      ]
      scale: {
        minReplicas: 1
        maxReplicas: 1
      }
    }
  }
}

// Reader role on the Container App for the shared managed identity, so the
// Web App dashboard can read the worker's live configuration via the ARM API.
// Role ID: acdd72a7-3385-48ef-bd42-f606fba81ae7 (Reader)
resource containerAppReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(containerApp.id, managedIdentity.id, 'Reader')
  scope: containerApp
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
    principalId: managedIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------- Outputs ----------

output webAppUrl string = 'https://${webApp.properties.defaultHostName}'
output functionAppUrl string = 'https://${functionApp.properties.defaultHostName}'
output keyVaultUri string = keyVault.properties.vaultUri
output webAppName string = webApp.name
output functionAppName string = functionApp.name
output funcStorageAccountName string = funcStorageAccount.name
output blobStorageAccountName string = blobStorageAccount.name
output storageBlobEndpoint string = blobStorageAccount.properties.primaryEndpoints.blob
output logoUrl string = '${blobStorageAccount.properties.primaryEndpoints.blob}${blobContainerName}/arpio-logo.svg'
output faviconUrl string = '${blobStorageAccount.properties.primaryEndpoints.blob}${blobContainerName}/arpio-favicon.png'
output containerAppName string = containerApp.name
output containerEnvName string = containerEnv.name
