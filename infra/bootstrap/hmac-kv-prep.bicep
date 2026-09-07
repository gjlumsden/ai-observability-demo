targetScope = 'resourceGroup'

@description('Name of the Key Vault to create or confirm.')
param keyVaultName string

@description('Azure region for the Key Vault.')
param location string

@description('Object ID of the deploying principal that needs temporary Key Vault Secrets Officer access.')
param deployingPrincipalId string

@description('Principal type for the temporary role assignment (User or ServicePrincipal).')
@allowed(['User', 'ServicePrincipal'])
param deployingPrincipalType string = 'User'

// Key Vault Secrets Officer built-in role definition ID.
var kvSecretsOfficerRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
)

// Properties match identity-vault.bicep exactly for idempotent re-deployment.
resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
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

// Narrowly scoped temporary role: Secrets Officer on this vault only.
// The preprovision hook removes this assignment immediately after writing the secret.
resource bootstrapRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, deployingPrincipalId, kvSecretsOfficerRoleId, 'preprovision-bootstrap')
  scope: keyVault
  properties: {
    roleDefinitionId: kvSecretsOfficerRoleId
    principalId: deployingPrincipalId
    principalType: deployingPrincipalType
  }
}

output keyVaultUri string = keyVault.properties.vaultUri
output keyVaultId string = keyVault.id
output bootstrapRoleAssignmentId string = bootstrapRole.id