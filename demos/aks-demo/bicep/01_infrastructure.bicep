/*
  ============================================================================
  AZURE INFRASTRUCTURE INCLUDING THE AKS CLUSTER
  Logical order: 01
  ============================================================================
  Azure equivalent of the EKS demo's VPC + EKS cluster + DynamoDB setup.

  AWS → Azure mapping
  ──────────────────────────────────────────────────────────────────────────
  VPC                          → Virtual Network (VNet)
  Public subnets               → publicSubnet  (for load balancers / App GW)
  Private subnets              → nodeSubnet    (AKS nodes – no direct internet)
  NAT Gateway                  → Azure NAT Gateway (same concept, same name)
  EKS Cluster                  → AKS Cluster
  Managed Node Group           → System node pool + User node pool
  VPC Endpoint (SSM)           → Azure Bastion / Cloud Shell (no equivalent needed)
  DynamoDB table               → Cosmos DB (NoSQL / SQL API)
  ============================================================================
*/

// ── Parameters ───────────────────────────────────────────────────────────────

@description('Short name that uniquely identifies this environment (e.g. eastus, dev1). Used in all resource names.')
param envName string

@description('Azure region for all resources (e.g. eastus, westus2).')
param location string = resourceGroup().location

@description('Kubernetes version for AKS.')
param kubernetesVersion string = '1.33'

@description('VM size for AKS node pool VMs.')
param vmSize string = 'Standard_D2s_v3'

@description('Resource name prefix (e.g. arpio). Combined with envName to form all resource names.')
param prefix string = 'aks-demo'

// ── Locals / name helpers ─────────────────────────────────────────────────────

var prefixEnv = '${prefix}-${envName}'

// Cosmos DB account names must be globally unique, 3-44 chars, lowercase.
// We truncate envName to keep total under 44 chars.
var shortEnv         = take(replace(envName, '-', ''), 8)
var clusterName      = '${prefixEnv}-cluster'
var cosmosAccountName = 'cosmos-${prefix}-${shortEnv}'

// ── Virtual Network ───────────────────────────────────────────────────────────
/*
  EKS needs a VPC with public + private subnets across multiple AZs.
  AKS needs a VNet with at minimum a node subnet. We follow the same pattern:
    - nodeSubnet   (10.0.1.0/24)  – AKS nodes run here; no public IPs on nodes
    - publicSubnet (10.0.101.0/24) – Internet-facing load balancers land here

  Azure CNI Overlay gives each pod an IP from a pod CIDR (not the VNet CIDR),
  so we don't need to over-size the VNet for pod addresses.
*/

resource vnet 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name:     '${prefixEnv}-vnet'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: ['10.0.0.0/16']
    }
    subnets: [
      {
        // AKS node subnet – nodes run here with NAT for outbound internet
        name: '${prefixEnv}-node-subnet'
        properties: {
          addressPrefix: '10.0.1.0/24'
          natGateway: { id: natGateway.id }
        }
      }
      {
        // Public subnet – internet-facing resources (load balancers, App Gateway)
        name: '${prefixEnv}-public-subnet'
        properties: {
          addressPrefix: '10.0.101.0/24'
        }
      }
    ]
  }
}

// ── NAT Gateway ───────────────────────────────────────────────────────────────
/*
  Allows AKS nodes in the private node subnet to reach the internet (for pulling
  container images, OS updates, etc.) without a public IP on each node.
  Equivalent to single_nat_gateway = true in the EKS demo.
*/

resource natGatewayIp 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name:     '${prefixEnv}-nat-ip'
  location: location
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource natGateway 'Microsoft.Network/natGateways@2023-09-01' = {
  name:     '${prefixEnv}-nat-gateway'
  location: location
  sku: { name: 'Standard' }
  properties: {
    publicIpAddresses: [{ id: natGatewayIp.id }]
    idleTimeoutInMinutes: 4
  }
}

// ── AKS Cluster Identity ──────────────────────────────────────────────────────
/*
  AKS uses a User-Assigned Managed Identity to manage Azure resources on your
  behalf (load balancers, disks, network interfaces).
  Equivalent to the IAM role the EKS control plane uses internally.
*/

resource aksIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name:     '${prefixEnv}-aks-identity'
  location: location
}

// Grant the AKS identity Network Contributor on the VNet so it can create
// load balancer NICs and attach node subnets.
resource aksNetworkContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name:  guid(vnet.id, aksIdentity.id, 'NetworkContributor')
  scope: vnet
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4d97b98b-1d4f-4787-a291-c67834d212e7') // Network Contributor
    principalId:      aksIdentity.properties.principalId
    principalType:    'ServicePrincipal'
  }
}

// ── AKS Cluster ───────────────────────────────────────────────────────────────
/*
  Azure Kubernetes Service – managed Kubernetes. Azure handles the control
  plane (API server, etcd, scheduler) at no cost. You pay for node VMs.

  Key differences from EKS:
  • Control plane is always free (EKS charges $0.10/hr)
  • Identity = Azure AD Workload Identity (vs IRSA on EKS)
  • Storage CSI drivers are built-in (no add-on needed)
  • Autoscaler is built-in (no Helm chart needed)
*/

resource aks 'Microsoft.ContainerService/managedClusters@2024-02-01' = {
  name:     clusterName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${aksIdentity.id}': {}
    }
  }
  properties: {
    dnsPrefix:         prefixEnv
    kubernetesVersion: kubernetesVersion

    // ── System node pool ────────────────────────────────────────────────────
    // Runs Kubernetes system components (CoreDNS, metrics-server).
    // Tainted so user workloads don't land here.
    // Equivalent to the first entry in eks_managed_node_groups.
    agentPoolProfiles: [
      {
        name:               'system'
        mode:               'System'
        count:              1
        minCount:           1
        maxCount:           2
        enableAutoScaling:  true
        vmSize:             vmSize
        vnetSubnetID:       '${vnet.id}/subnets/${prefixEnv}-node-subnet'
        nodeTaints:         ['CriticalAddonsOnly=true:NoSchedule']
        osType:             'Linux'
        osDiskSizeGB:       50
        upgradeSettings:    { maxSurge: '10%' }
      }
      // ── User node pool ──────────────────────────────────────────────────
      // Application workloads run here. min=1, desired=2, max=3 matches the
      // EKS demo's min_size=1 / desired_size=2 / max_size=3.
      {
        name:               'user'
        mode:               'User'
        count:              2
        minCount:           1
        maxCount:           3
        enableAutoScaling:  true
        vmSize:             vmSize
        vnetSubnetID:       '${vnet.id}/subnets/${prefixEnv}-node-subnet'
        osType:             'Linux'
        osDiskSizeGB:       50
        upgradeSettings:    { maxSurge: '10%' }
      }
    ]

    // ── Networking ──────────────────────────────────────────────────────────
    // azure CNI overlay: pods get IPs from a pod CIDR, not the VNet CIDR.
    // Equivalent to the VPC CNI plugin on EKS.
    // outboundType: userAssignedNATGateway → use our NAT gateway (not a managed one).
    networkProfile: {
      networkPlugin:     'azure'
      networkPluginMode: 'overlay'
      loadBalancerSku:   'standard'
      outboundType:      'userAssignedNATGateway'
      // These must not overlap the VNet (10.0.0.0/16) or each other.
      // podCidr is safe to overlap the VNet in CNI Overlay mode (pods are
      // encapsulated and never routed on the VNet directly).
      podCidr:       '10.244.0.0/16'   // standard overlay pod range
      serviceCidr:   '10.96.0.0/16'    // Kubernetes in-cluster service VIPs
      dnsServiceIP:  '10.96.0.10'      // must be within serviceCidr
    }

    // ── Azure AD Workload Identity ──────────────────────────────────────────
    // Equivalent to enabling IRSA / OIDC on EKS.
    // oidcIssuerProfile + securityProfile.workloadIdentity = Workload Identity.
    // Pods annotated with a managed identity client ID get Azure credentials
    // injected automatically — same mechanism as IRSA on EKS.
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }

    // ── Azure Monitor ────────────────────────────────────────────────────────
    // Container Insights — equivalent to CloudWatch Container Insights on EKS.
    azureMonitorProfile: {
      metrics: {
        enabled: true
      }
    }

    // ── Cluster autoscaler ───────────────────────────────────────────────────
    // Built-in. Enabled per-node-pool via enableAutoScaling above.
    // No separate Helm chart or IAM policy needed (unlike the EKS demo).
    autoScalerProfile: {
      'balance-similar-node-groups': 'true'    // equivalent to extraArgs.balance-similar-node-groups
      'skip-nodes-with-system-pods': 'false'   // equivalent to extraArgs.skip-nodes-with-system-pods
      'scale-down-delay-after-add':  '10m'
      'scale-down-unneeded-time':    '10m'
    }

    // ── Key Vault Secrets Store CSI add-on ───────────────────────────────────
    // Managed AKS add-on — do NOT use Microsoft.KubernetesConfiguration/extensions
    // (that API is for Arc-connected clusters, not managed AKS).
    // Equivalent to the EKS demo's helm_release.secrets_store_csi_driver +
    // the manual AWS provider DaemonSet, but fully managed here.
    addonProfiles: {
      azureKeyvaultSecretsProvider: {
        enabled: true
        config: {
          enableSecretRotation: 'true'
          rotationPollInterval: '2m'
        }
      }
    }
  }

  dependsOn: [aksNetworkContributor]
}

// ── Cosmos DB (NoSQL API) ─────────────────────────────────────────────────────
/*
  Azure equivalent of the DynamoDB guestbook table in the EKS demo.

  AWS → Azure mapping
  ─────────────────────────────────────────────────────────────────────────────
  DynamoDB table            → Cosmos DB container
  Partition key (GuestID)   → Partition key (/guestId)
  DDB Streams               → Cosmos DB Change Feed  (always-on, no flag needed)
  Point-in-time recovery    → Continuous backup (7-day window)
  Provisioned RCU/WCU = 2   → 400 RU/s (minimum)
  Gateway VPC Endpoint      → Public endpoint (Private Endpoint = extension exercise)
*/

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-02-15-preview' = {
  name:     cosmosAccountName
  location: location
  kind:     'GlobalDocumentDB'    // NoSQL API
  properties: {
    databaseAccountOfferType: 'Standard'
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName:     location
        failoverPriority: 0
        isZoneRedundant:  false
      }
    ]
    // Change Feed is always enabled on Cosmos DB – no flag needed.
    // Equivalent to DDB Streams stream_enabled = true / stream_view_type = "NEW_IMAGE".

    // Continuous backup → equivalent to DDB point_in_time_recovery { enabled = true }.
    backupPolicy: {
      type: 'Continuous'
      continuousModeProperties: {
        tier: 'Continuous7Days'
      }
    }
  }
}

resource cosmosDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-02-15-preview' = {
  parent: cosmosAccount
  name:   'guestbook'
  properties: {
    resource: { id: 'guestbook' }
  }
}

resource cosmosContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-02-15-preview' = {
  parent: cosmosDatabase
  name:   'guests'
  properties: {
    resource: {
      id:           'guests'
      partitionKey: {
        paths: ['/guestId']
        kind:  'Hash'
      }
    }
    options: {
      throughput: 400    // Minimum RU/s; use autoscale in production
    }
  }
}

// ── Outputs (consumed by later Bicep files and deploy script) ─────────────────

output aksClusterName   string = aks.name
output vnetId           string = vnet.id
output nodeSubnetId     string = vnet.properties.subnets[0].id
output publicSubnetId   string = vnet.properties.subnets[1].id
output oidcIssuerUrl    string = aks.properties.oidcIssuerProfile.issuerURL
output cosmosEndpoint   string = cosmosAccount.properties.documentEndpoint
output cosmosAccountName string = cosmosAccount.name
output cosmosDatabaseName string = cosmosDatabase.name
output cosmosContainerName string = cosmosContainer.name
output prefixEnv        string = prefixEnv
