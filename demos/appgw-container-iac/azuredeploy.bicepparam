using './azuredeploy.bicep'

param location = 'centralus'
param baseName = 'appgw-aci'
param acrName = 'demoacre7e3f'
param acrResourceGroup = 'rg-demo-acr'
param containerImage = 'demoacre7e3f.azurecr.io/demo-app:latest'
param usePrivateEndpoints = true
