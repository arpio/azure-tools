using './azuredeploy.bicep'

param location = 'eastus2'
param vmAdminUsername = 'azureuser'
param sshPublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKSQw9tZCGd+x2jBUpo6j5QAFhMaozksCaUGeN9nbZSg seliot@arpio.io'
param vmSku = 'Standard_B1s'
param instanceCount = 2

// SQL params
param baseName = 'app-sql'
param sqlAdminLogin = 'sqladminuser'
param sqlDbName = 'appdb'
param sqlAdminPassword = 'Pa$$w0rd123!'
