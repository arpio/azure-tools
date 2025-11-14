# Load Balancer - Server - Database stack

This folder contains Infrastructure as Code (IaC) configuration to deploy a **Load Balancer - Server - Database** stack.

**Bicep templates are being kept up to date.** ARM templates are here for historical purposes only

The deployed workload looks like this:
![architecture](images/lb-server-db.png)

* The servers are reachable through the Load Balancer and will return the server name
* However, the VMs (servers) do not actually communicate with the DB. Adding this is a TODO item.

## Deployment

Ensure you are in the correct subscription
```bash
az account set --subscription <subscription_id>
```

If this is a new deployment and you are using a new resource group, then create it
```bash
az group create -n <resource_group_name> -l <region>
```

Bicep
```bash
az deployment group create \
  --name lb-server-db-bicep \
  --resource-group <resource_group_name> \
  --template-file azuredeploy.bicep \
  --parameters azuredeploy.bicepparam
```

ARM
```bash
az deployment group create \
  --name lb-server-db-arm \
  --resource-group <resource_group_name> \
  --template-file azuredeploy.json \
  --parameters @azuredeploy.parameters.json
```
