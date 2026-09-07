targetScope = 'resourceGroup'

@description('Azure region for Key Vault resources.')
param location string

@description('Tags applied to Key Vault resources.')
param tags object

@description('Stable suffix used in resource names.')
param resourceSuffix string

var cleanSuffix = toLower(replace(resourceSuffix, '-', ''))
var keyVaultName = take('aiobs-kv-${cleanSuffix}', 24)
var secretName = 'usage-hmac-key'

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enablePurgeProtection: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

output keyVaultName string = keyVault.name
output keyVaultId string = keyVault.id
output secretName string = secretName
output secretIdentifier string = '${keyVault.properties.vaultUri}secrets/${secretName}'