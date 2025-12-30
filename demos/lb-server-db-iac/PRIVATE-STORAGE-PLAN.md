# Plan: Private Storage with Managed Identity

## Goal
Make the scripts storage account private and use VM managed identities to access it. This demonstrates identity recovery in Arpio.

## Current State
- Storage account: `allowBlobPublicAccess: true`
- Container: `publicAccess: 'Blob'`
- VMs download scripts via public URL (`curl`)
- No managed identities on VMs

## Target State
- Storage account: `allowBlobPublicAccess: false`
- Container: `publicAccess: 'None'`
- VMs have system-assigned managed identities
- VMs download scripts using managed identity auth
- Custom Script Extension uses managed identity to fetch scripts

## Files to Modify

### 1. azuredeploy.bicep

#### Storage Account (line ~166)
```bicep
// Change:
allowBlobPublicAccess: true
// To:
allowBlobPublicAccess: false
```

#### Container (line ~187)
```bicep
// Change:
publicAccess: 'Blob'
// To:
publicAccess: 'None'
```

#### VMSS (line ~296)
```bicep
resource vmss ... {
  name: 'vmss-app'
  location: location
  identity: {
    type: 'SystemAssigned'  // ADD THIS
  }
  sku: ...
```

#### Standalone VM (line ~476)
```bicep
resource vmStandalone ... {
  name: 'vm-standalone'
  location: location
  identity: {
    type: 'SystemAssigned'  // ADD THIS
  }
  properties: ...
```

#### New Role Assignments (after storage resources)
```bicep
// Role assignment: Storage Blob Data Reader for VMSS
resource vmssStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(scriptsStorage.id, vmss.id, 'Storage Blob Data Reader')
  scope: scriptsStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1') // Storage Blob Data Reader
    principalId: vmss.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Role assignment: Storage Blob Data Reader for standalone VM
resource vmStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(scriptsStorage.id, vmStandalone.id, 'Storage Blob Data Reader')
  scope: scriptsStorage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1')
    principalId: vmStandalone.identity.principalId
    principalType: 'ServicePrincipal'
  }
}
```

#### Custom Script Extensions
Add `managedIdentity` to protectedSettings and update fileUris format:

```bicep
// VMSS Extension
resource vmssCustomScript ... {
  properties: {
    ...
    settings: {
      fileUris: [
        '${scriptsBaseUrl}/vm-setup.sh'
        '${scriptsBaseUrl}/app.py'  // Download both files via extension
      ]
      commandToExecute: 'bash vm-setup.sh'  // No need to pass URL anymore
    }
    protectedSettings: {
      managedIdentity: {}  // Use VM's system-assigned identity
    }
  }
  dependsOn: [
    vmssStorageRoleAssignment  // Ensure role assignment exists first
  ]
}
```

Same pattern for standalone VM extension.

### 2. scripts/vm-setup.sh

Remove the URL argument and curl download since extension downloads both files:

```bash
#!/bin/bash
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# Files are already downloaded by Custom Script Extension to current directory
# No need to download app.py - it's already here

# Update and install base dependencies
apt-get update
apt-get install -y python3 python3-pip python3-venv curl gnupg jq

# Install Microsoft ODBC driver for SQL Server
# ... (rest stays the same)

# Copy the Flask application (already downloaded by extension)
cp app.py /opt/demo-app/app.py

# ... rest of script unchanged
```

## Deployment Order Considerations

The managed identity is created when the VM/VMSS is created, but the role assignment needs the principalId from that identity. Bicep handles this automatically with implicit dependencies when you reference `vmss.identity.principalId`.

However, the Custom Script Extension needs the role assignment to be complete before it can download. Add explicit `dependsOn` to ensure correct ordering:

```
VM/VMSS created (identity created)
    ↓
Role assignment created (grants identity access to storage)
    ↓
Custom Script Extension runs (uses identity to download scripts)
```

## Testing

1. Delete existing VMSS and VM
2. Deploy updated template
3. Verify VMs have managed identities in Azure Portal
4. Verify extension succeeded (Portal → VM → Extensions)
5. Test Arpio recovery - identity should be recreated in DR region

## Arpio Considerations

When Arpio recovers VMs to a new region:
- System-assigned managed identities are recreated (new principalId)
- Role assignments reference the old principalId and need to be updated
- This demonstrates Arpio's identity recovery capabilities
