using './azuredeploy.bicep'

param location = 'centralus'
param vmAdminUsername = 'azureuser'
param sshPublicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIXjOY/qeMYYLmcm9PMiUV0IohU83xFp19+pvcxcFVJD seth@Seths-MacBook-Air-2.local'
//param vmSku = 'Standard_B1s'
param vmSku = 'Standard_B2ps_v2'
param instanceCount = 2

// SQL params
param baseName = 'app-sql'
param sqlAdminLogin = 'sqladminuser'
param sqlDbName = 'appdb'

