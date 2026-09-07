targetScope = 'resourceGroup'

@description('Name of the existing FinOps hub storage account.')
param storageAccountName string

@description('Principal ID of the FinOps Data Factory managed identity.')
param dataFactoryPrincipalId string

var rbacAdministratorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
)

resource hubStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

// Cost Management uses the caller's permission to grant each export identity container access.
resource exportStorageAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(hubStorage.id, dataFactoryPrincipalId, rbacAdministratorRoleId)
  scope: hubStorage
  properties: {
    roleDefinitionId: rbacAdministratorRoleId
    principalId: dataFactoryPrincipalId
    principalType: 'ServicePrincipal'
    description: 'Allow FinOps managed exports to grant their identities access within this hub storage account.'
  }
}

output roleAssignmentId string = exportStorageAccess.id
