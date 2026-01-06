# Load Balancer - Server - Database stack

This folder contains Infrastructure as Code (IaC) configuration to deploy a **Load Balancer - Server - Database** stack.

**Bicep templates are being kept up to date.** ARM templates are here for historical purposes only

The deployed workload looks like this:
![architecture](images/lb-server-db.png)

The workload includes the following resources:
* Single standalone VM and multiple VMSS-based VMs
* Azure SQL Database 
* Load Balancer targeting both standalone and VMSS VMs
* All servers are running a simple Flask app that reads and writes to the DB
* Bastions are deployed to access the VMs
* Azure Storage Account containing code and scripts in Blob Storage for use by the VMs
* NAT Gateway

The Bicep template does all necessary initialization, including uploading the scripts and configuring VM user data to use them.

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

