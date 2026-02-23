# Plan: Add Service Endpoint for Azure SQL

Restrict SQL Server inbound access so only VMs in `subnet-app` can connect,
instead of the current wide-open `AllowAllIP` firewall rule.

## What is a service endpoint?

A service endpoint routes traffic from a VNet subnet to an Azure service
(in this case SQL) over the Azure backbone network. The traffic still hits
the service's public FQDN, but Azure recognizes the source subnet and can
enforce VNet-based access rules. Service endpoints are free.

## Service endpoint vs. private endpoint

Both approaches route traffic over the Azure backbone (not the public internet).
In both cases traffic ultimately leaves your VNet to reach the Azure SQL service
infrastructure — SQL doesn't run inside your VNet.

| | Service Endpoint | Private Endpoint |
|---|---|---|
| **How VMs connect** | Via SQL's public FQDN and public IP | Via a private IP in your VNet (NIC created for you) |
| **SQL has a public IP?** | Yes | Can be disabled entirely |
| **Traffic path** | VNet → Azure backbone → SQL public endpoint | VNet → private IP NIC → Azure backbone → SQL |
| **DNS** | Resolves to public IP as usual | Private DNS zone resolves FQDN to private IP |
| **Cost** | Free | ~$7.30/month + data processing fees |
| **Complexity** | Low (subnet flag + VNet rule) | Higher (NIC, private DNS zone, DNS zone link) |
| **Cross-VNet / on-prem access** | No (only from the enabled subnet) | Yes (private IP reachable from peered VNets, VPN, ExpressRoute) |

This plan uses service endpoints — simpler and sufficient for this demo.

## Changes to `azuredeploy.bicep`

### 1. Add `Microsoft.Sql` service endpoint to the app subnet

In the VNet resource, add `serviceEndpoints` to `subnet-app`:

```bicep
{
  name: subnetName
  properties: {
    addressPrefix: '10.0.0.0/24'
    networkSecurityGroup: { id: nsg.id }
    natGateway: { id: natGateway.id }
    serviceEndpoints: [
      { service: 'Microsoft.Sql' }
    ]
  }
}
```

### 2. Add a VNet rule on the SQL Server

Create a new child resource that allows connections from `subnet-app`:

```bicep
resource sqlVnetRule 'Microsoft.Sql/servers/virtualNetworkRules@2023-08-01' = {
  name: 'allow-app-subnet'
  parent: sql
  properties: {
    virtualNetworkSubnetId: resourceId(
      'Microsoft.Network/virtualNetworks/subnets', vnetName, subnetName
    )
  }
}
```

### 3. Remove the `AllowAllIP` firewall rule

Delete the `fwAllowAllIP` resource, which currently opens SQL to the
entire internet (`0.0.0.0` – `255.255.255.255`):

```bicep
// DELETE THIS:
resource fwAllowAllIP 'Microsoft.Sql/servers/firewallRules@2023-08-01' = {
  name: 'AllowAllIP'
  parent: sql
  ...
}
```

### 4. Keep `AllowAllAzureServices` (optional)

The `fwAllowAzure` rule (`0.0.0.0` – `0.0.0.0`) allows other Azure
services to connect to SQL. Keep it if Azure services outside the VNet
(e.g., the deployment script) need SQL access. Remove it if you want
maximum lockdown and only VNet-based access.

## What does NOT change

- **Outbound firewall rules** — The existing `outboundFwBlobStorage` rule
  controls what SQL can reach *out to*. Service endpoints control *inbound*
  access to SQL. These are independent; no outbound changes needed.
- **Storage account** — This plan only adds a service endpoint for SQL.
  Storage remains publicly accessible. See `PRIVATE-STORAGE-PLAN.md` for
  the storage lockdown plan.
- **NAT Gateway** — Still required for general outbound internet access
  from the VMs (apt packages, etc.).

## Rollback

To revert: remove the `serviceEndpoints` entry from the subnet, delete the
`sqlVnetRule` resource, and re-add the `fwAllowAllIP` firewall rule.
