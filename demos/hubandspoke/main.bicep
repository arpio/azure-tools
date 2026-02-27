// ============================================
// Main Orchestrator Template
// ============================================
// Deploys complete hub-spoke architecture with:
// - Hub VNet (Bastion, VPN Gateway)
// - App 1 VNet (Load Balancer, VMSS, Database VM)
// - App 2 VNet (Windows VM with User Assigned Identity)
// - Bidirectional VNet peering

targetScope = 'subscription'

@description('Prefix for all resource names')
param resourcePrefix string

@description('Azure region for all resources')
param location string

@description('Admin username for VMs')
param adminUsername string = 'azureuser'

@description('Admin password for VMs')
@secure()
param adminPassword string

@description('Hub VNet address prefix')
param hubVnetAddressPrefix string = '10.0.0.0/16'

@description('App 1 VNet address prefix')
param app1VnetAddressPrefix string = '10.1.0.0/16'

@description('App 2 VNet address prefix')
param app2VnetAddressPrefix string = '10.2.0.0/16'

@description('VM size for all linux/ARM VMs')
param vmSizeLinux string = 'Standard_B2PS_v2'

@description('VM size for all Windows VMs')
param vmSizeWindows string = 'Standard_D2ads_v7'

@description('VMSS instance count for App1')
param vmssInstanceCount int = 2

@description('Tags to apply to all resources')
param tags object = {
  Environment: 'Demo'
  ManagedBy: 'Bicep'
  Architecture: 'Hub-Spoke'
}

@description('Deploy PaaS application stack (optional)')
param deployPaasApplication bool = false

@description('Secret value for PaaS Key Vault (required if deployPaasApplication is true)')
@secure()
param paasSecretValue string = ''

// ============================================
// Resource Groups (One per component)
// ============================================
resource hubRg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: '${resourcePrefix}-hub-rg'
  location: location
  tags: union(tags, { Component: 'Hub' })
}

resource app1Rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: '${resourcePrefix}-app1-rg'
  location: location
  tags: union(tags, { Component: 'App1' })
}

resource app2Rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: '${resourcePrefix}-app2-rg'
  location: location
  tags: union(tags, { Component: 'App2' })
}

resource paasRg 'Microsoft.Resources/resourceGroups@2021-04-01' = if (deployPaasApplication) {
  name: '${resourcePrefix}-paas-rg'
  location: location
  tags: union(tags, { Component: 'PaaS-Application' })
}

// ============================================
// Hub VNet (Landing Zone)
// ============================================
module hubVnet 'script/modules/hub-vnet.bicep' = {
  scope: hubRg
  name: 'deploy-hub-vnet'
  params: {
    resourcePrefix: resourcePrefix
    location: location
    hubVnetAddressPrefix: hubVnetAddressPrefix
    tags: tags
  }
}

// ============================================
// App 1 VNet (VMSS + Database VM)
// ============================================
module app1Vnet 'script/modules/app1-vnet.bicep' = {
  scope: app1Rg
  name: 'deploy-app1-vnet'
  params: {
    resourcePrefix: resourcePrefix
    location: location
    app1VnetAddressPrefix: app1VnetAddressPrefix
    bastionSubnetAddressPrefix: hubVnet.outputs.bastionSubnetAddressPrefix
    spokeRouteTableId: hubVnet.outputs.spokeRouteTableId
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmssInstanceCount: vmssInstanceCount
    vmSizeLinux: vmSizeLinux
    tags: tags
  }
}

// ============================================
// App 2 VNet (Windows VM)
// ============================================
module app2Vnet 'script/modules/app2-vnet.bicep' = {
  scope: app2Rg
  name: 'deploy-app2-vnet'
  params: {
    resourcePrefix: resourcePrefix
    location: location
    app2VnetAddressPrefix: app2VnetAddressPrefix
    bastionSubnetAddressPrefix: hubVnet.outputs.bastionSubnetAddressPrefix
    spokeRouteTableId: hubVnet.outputs.spokeRouteTableId
    adminUsername: adminUsername
    adminPassword: adminPassword
    vmSize: vmSizeWindows
    tags: tags
  }
}

// ============================================
// VNet Peerings (deployed to Hub resource group)
// ============================================

// Hub to App1 peering
module hubToApp1Peering 'script/modules/vnet-peering.bicep' = {
  scope: hubRg
  name: 'deploy-hub-app1-peering'
  params: {
    localVnetName: hubVnet.outputs.hubVnetName
    remoteVnetName: app1Vnet.outputs.app1VnetName
    remoteVnetId: app1Vnet.outputs.app1VnetId
    allowForwardedTraffic: true
    allowGatewayTransit: true
    useRemoteGateways: false
  }
}

// App1 to Hub peering
module app1ToHubPeering 'script/modules/vnet-peering.bicep' = {
  scope: app1Rg
  name: 'deploy-app1-hub-peering'
  params: {
    localVnetName: app1Vnet.outputs.app1VnetName
    remoteVnetName: hubVnet.outputs.hubVnetName
    remoteVnetId: hubVnet.outputs.hubVnetId
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: true
  }
}

// Hub to App2 peering
module hubToApp2Peering 'script/modules/vnet-peering.bicep' = {
  scope: hubRg
  name: 'deploy-hub-app2-peering'
  params: {
    localVnetName: hubVnet.outputs.hubVnetName
    remoteVnetName: app2Vnet.outputs.app2VnetName
    remoteVnetId: app2Vnet.outputs.app2VnetId
    allowForwardedTraffic: true
    allowGatewayTransit: true
    useRemoteGateways: false
  }
}

// App2 to Hub peering
module app2ToHubPeering 'script/modules/vnet-peering.bicep' = {
  scope: app2Rg
  name: 'deploy-app2-hub-peering'
  params: {
    localVnetName: app2Vnet.outputs.app2VnetName
    remoteVnetName: hubVnet.outputs.hubVnetName
    remoteVnetId: hubVnet.outputs.hubVnetId
    allowForwardedTraffic: true
    allowGatewayTransit: false
    useRemoteGateways: true
  }
}

// ============================================
// Optional: PaaS Application Stack
// (Standalone, not connected to hub-spoke VNets)
// ============================================
module paasApplication 'script/modules/paas-application.bicep' = if (deployPaasApplication) {
  scope: paasRg
  name: 'deploy-paas-application'
  params: {
    resourcePrefix: '${resourcePrefix}-paas'
    location: location
    secretValue: paasSecretValue
    sqlAdminUsername: adminUsername
    sqlAdminPassword: adminPassword
    tags: union(tags, { Component: 'PaaS-Application' })
  }
}

// ============================================
// Outputs
// ============================================
// Resource Groups
output hubResourceGroupName string = hubRg.name
output app1ResourceGroupName string = app1Rg.name
output app2ResourceGroupName string = app2Rg.name
output paasResourceGroupName string = deployPaasApplication ? paasRg!.name : ''

// Hub VNet outputs
output hubVnetId string = hubVnet.outputs.hubVnetId
output bastionPublicIp string = hubVnet.outputs.bastionPublicIp
output vpnGatewayPublicIp string = hubVnet.outputs.vpnGatewayPublicIp

// App 1 outputs
output app1VnetId string = app1Vnet.outputs.app1VnetId
output app1LoadBalancerPublicIp string = app1Vnet.outputs.loadBalancerPublicIp
output app1VmssName string = app1Vnet.outputs.vmssName
output app1DbVmPrivateIp string = app1Vnet.outputs.dbVmPrivateIp

// App 2 outputs
output app2VnetId string = app2Vnet.outputs.app2VnetId
output app2VmName string = app2Vnet.outputs.vmName
output app2VmPrivateIp string = app2Vnet.outputs.vmPrivateIp
output app2UserIdentityId string = app2Vnet.outputs.userIdentityId

// PaaS Application outputs (if deployed)
output paasAppGatewayPublicIp string = deployPaasApplication ? paasApplication!.outputs.appGatewayPublicIp : ''
output paasAppGatewayUrl string = deployPaasApplication ? paasApplication!.outputs.appGatewayUrl : ''
output paasAppGatewayContainerUrl string = deployPaasApplication ? paasApplication!.outputs.appGatewayContainerUrl : ''
output paasWebAppUrl string = deployPaasApplication ? paasApplication!.outputs.webAppUrl : ''
output paasKeyVaultUri string = deployPaasApplication ? paasApplication!.outputs.keyVaultUri : ''
output paasSqlServerFqdn string = deployPaasApplication ? paasApplication!.outputs.sqlServerFqdn : ''

// Connection instructions
output connectionInstructions string = '''
=== Connection Instructions ===

Resource Groups:
- Hub: ${hubRg.name}
- App 1: ${app1Rg.name}
- App 2: ${app2Rg.name}${deployPaasApplication ? concat('\n- PaaS: ', paasRg!.name) : ''}

1. Azure Bastion: Connect via Azure Portal
   - Go to the ${hubRg.name} resource group
   - Find the Bastion resource
   - Use Bastion to connect to any VM in the spoke VNets

2. App 1 Load Balancer: 
   - HTTP: http://${app1Vnet.outputs.loadBalancerPublicIp}
   - HTTPS: https://${app1Vnet.outputs.loadBalancerPublicIp}

3. VPN Gateway: Configure VPN client
   - Public IP: ${hubVnet.outputs.vpnGatewayPublicIp}
   - Configure P2S VPN in Azure Portal

Note: VPN Gateway takes 30-45 minutes to deploy.
'''
