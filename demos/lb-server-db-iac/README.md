# Load Balancer - Server - Database stack

This folder contains Infrastructure as Code (IaC) configuration to deploy a **Load Balancer - Server - Database** stack.

**Bicep templates are being kept up to date.** ARM templates are here for historical purposes only

The deployed workload looks like this:
![architecture](images/lb-server-db.png)

* A single standalone VM and two VMSS-based VMs are deployed
* All servers are reachable through the Load Balancer
* The servers are running a simple Flask app that reads and writes to the DB
* Bastions are deployed to access the VMs
* An Azure Storage Account is created
* Code and scripts are uploaded to the Storage Account as Blob Storage for use by the VMs
![alt text](images/demo_app.png)

## Deployment

Ensure you are in the correct subscription
```bash
az account set --subscription <subscription_id>
```

If this is a new deployment and you are using a new resource group, then create it
```bash
az group create -n <resource_group_name> -l <region>
```

```bash
az deployment group create \
  --name lb-server-db-bicep \
  --resource-group <resource_group_name> \
  --template-file azuredeploy.bicep \
  --parameters azuredeploy.bicepparam
```

