// =============================================================================
// Network Module
// =============================================================================
// Provisions a VNet and subnet for custom-network and private-network configs.
// Deployed into the infra resource group, separate from the cluster RG.
// =============================================================================

@description('Name of the virtual network.')
param vnetName string

@description('Name of the subnet for AKS nodes.')
param subnetName string

@description('Azure region.')
param location string = resourceGroup().location

@description('Address space for the VNet.')
param vnetAddressPrefix string = '10.0.0.0/8'

@description('Address prefix for the AKS node subnet.')
param subnetAddressPrefix string = '10.240.0.0/16'

// ---------------------------------------------------------------------------
// Virtual Network
// ---------------------------------------------------------------------------

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name:     vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressPrefix]
    }
  }
}

// Defined as a child resource rather than inline so the output reference is
// symbolic rather than index-based (subnets[0].id breaks if order ever changes).
resource subnet 'Microsoft.Network/virtualNetworks/subnets@2023-09-01' = {
  parent: vnet
  name:   subnetName
  properties: {
    addressPrefix: subnetAddressPrefix
    // Private endpoint policies disabled to allow AKS private endpoint
    // if the cluster is configured as private-network.
    privateEndpointNetworkPolicies:    'Disabled'
    privateLinkServiceNetworkPolicies: 'Disabled'
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output vnetId   string = vnet.id
output vnetName string = vnet.name
output subnetId string = subnet.id
