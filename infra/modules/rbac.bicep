targetScope = 'resourceGroup'

@description('Azure region parameter retained for consistent module composition.')
#disable-next-line no-unused-params
param location string

@description('Tags parameter retained for consistent module composition.')
#disable-next-line no-unused-params
param tags object

@description('Stable suffix parameter retained for consistent module composition.')
#disable-next-line no-unused-params
param resourceSuffix string

@description('Microsoft Foundry account name.')
param foundryName string

@description('Current user principal ID. Leave empty to skip current-user assignments.')
param currentUserPrincipalId string = ''

@description('APIM managed identity principal ID. Leave empty to skip APIM assignments.')
param apimPrincipalId string = ''

var cognitiveServicesUserRoleId = 'a97b65f3-24c7-4388-baec-2e87135dc908'
var azureAiDeveloperRoleId = '64702f94-c441-49e6-a78b-ef80e0188fee'
var azureAiUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'
var azureAiProjectManagerRoleId = 'eadc314b-1a2d-4efa-be10-5d325db5065e'
var azureAiAdministratorRoleId = 'b78c5d69-af96-48a3-bf8d-a8b4d589de94'
var cognitiveServicesOpenAiContributorRoleId = 'a001fd3d-188f-4b5d-821b-7da978bf7442'
var cognitiveServicesOpenAiUserRoleId = '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd'

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: foundryName
}

resource currentUserFoundryAzureAiDeveloper 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(currentUserPrincipalId)) {
  name: guid(foundry.id, currentUserPrincipalId, azureAiDeveloperRoleId)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureAiDeveloperRoleId)
    principalId: currentUserPrincipalId
  }
}

resource currentUserFoundryCognitiveServicesUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(currentUserPrincipalId)) {
  name: guid(foundry.id, currentUserPrincipalId, cognitiveServicesUserRoleId)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: currentUserPrincipalId
  }
}

resource currentUserFoundryAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(currentUserPrincipalId)) {
  name: guid(foundry.id, currentUserPrincipalId, azureAiUserRoleId)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureAiUserRoleId)
    principalId: currentUserPrincipalId
  }
}

resource currentUserFoundryProjectManager 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(currentUserPrincipalId)) {
  name: guid(foundry.id, currentUserPrincipalId, azureAiProjectManagerRoleId)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureAiProjectManagerRoleId)
    principalId: currentUserPrincipalId
  }
}

resource currentUserFoundryAdministrator 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(currentUserPrincipalId)) {
  name: guid(foundry.id, currentUserPrincipalId, azureAiAdministratorRoleId)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureAiAdministratorRoleId)
    principalId: currentUserPrincipalId
  }
}

resource currentUserFoundryOpenAiContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(currentUserPrincipalId)) {
  name: guid(foundry.id, currentUserPrincipalId, cognitiveServicesOpenAiContributorRoleId)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAiContributorRoleId)
    principalId: currentUserPrincipalId
  }
}

resource apimFoundryCognitiveServicesUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(apimPrincipalId)) {
  name: guid(foundry.id, apimPrincipalId, cognitiveServicesUserRoleId)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesUserRoleId)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource apimFoundryAzureAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(apimPrincipalId)) {
  name: guid(foundry.id, apimPrincipalId, azureAiUserRoleId)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureAiUserRoleId)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource apimFoundryAzureAiDeveloper 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(apimPrincipalId)) {
  name: guid(foundry.id, apimPrincipalId, azureAiDeveloperRoleId)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', azureAiDeveloperRoleId)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}

resource apimFoundryOpenAiUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(apimPrincipalId)) {
  name: guid(foundry.id, apimPrincipalId, cognitiveServicesOpenAiUserRoleId)
  scope: foundry
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', cognitiveServicesOpenAiUserRoleId)
    principalId: apimPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output currentUserAssignmentsConfigured bool = !empty(currentUserPrincipalId)
output apimAssignmentsConfigured bool = !empty(apimPrincipalId)
output rbacConfigured bool = true
