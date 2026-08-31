targetScope = 'resourceGroup'

@description('Azure region for Event Hubs.')
param location string

@description('Tags applied to Event Hubs resources.')
param tags object

@description('Stable suffix used in resource names.')
param resourceSuffix string

@description('Name of the usage storage account.')
param storageAccountName string

@description('Name of the blob container used by Event Hubs Capture.')
param captureContainerName string

@description('Log Analytics workspace resource ID for diagnostics.')
param logAnalyticsWorkspaceId string

var cleanSuffix = toLower(replace(resourceSuffix, '-', ''))
var namespaceName = take('aiobs-usage-eh-${cleanSuffix}', 50)
var eventHubName = 'ai-usage'
var consumerGroupName = 'processor'
var storageBlobDataContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
)

resource captureIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'aiobs-usage-capture-${cleanSuffix}'
  location: location
  tags: tags
}

resource usageStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource usageBlobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' existing = {
  parent: usageStorage
  name: 'default'
}

resource usageCaptureContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' existing = {
  parent: usageBlobService
  name: captureContainerName
}

resource captureStorageWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(usageCaptureContainer.id, captureIdentity.id, storageBlobDataContributorRoleId)
  scope: usageCaptureContainer
  properties: {
    roleDefinitionId: storageBlobDataContributorRoleId
    principalId: captureIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

module eventHubNamespace 'br/public:avm/res/event-hub/namespace:0.15.0' = {
  params: {
    name: namespaceName
    location: location
    tags: tags
    skuName: 'Standard'
    skuCapacity: 1
    zoneRedundant: false
    isAutoInflateEnabled: false
    disableLocalAuth: true
    authorizationRules: []
    minimumTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    managedIdentities: {
      userAssignedResourceId: captureIdentity.id
    }
    eventhubs: [
      {
        name: eventHubName
        partitionCount: 2
        messageRetentionInDays: 7
        consumergroups: [
          {
            name: consumerGroupName
            userMetadata: 'AI usage processor checkpoint group'
          }
        ]
        captureDescription: {
          enabled: true
          encoding: 'Avro'
          intervalInSeconds: 300
          sizeLimitInBytes: 314572800
          skipEmptyArchives: true
          destination: {
            name: 'EventHubArchive.AzureBlockBlob'
            identity: {
              userAssignedResourceId: captureIdentity.id
            }
            properties: {
              storageAccountResourceId: usageStorage.id
              blobContainer: usageCaptureContainer.name
              archiveNameFormat: '{Namespace}/{EventHub}/{PartitionId}/{Year}/{Month}/{Day}/{Hour}/{Minute}/{Second}'
            }
          }
        }
      }
    ]
    diagnosticSettings: [
      {
        name: 'send-to-log-analytics'
        workspaceResourceId: logAnalyticsWorkspaceId
        logCategoriesAndGroups: [
          {
            categoryGroup: 'allLogs'
          }
        ]
        metricCategories: [
          {
            category: 'AllMetrics'
          }
        ]
      }
    ]
  }
  dependsOn: [
    captureStorageWriter
  ]
}

output namespaceName string = eventHubNamespace.outputs.name
output namespaceId string = eventHubNamespace.outputs.resourceId
output namespaceFullyQualifiedName string = '${eventHubNamespace.outputs.name}.servicebus.windows.net'
output eventHubName string = eventHubName
output eventHubId string = resourceId(
  'Microsoft.EventHub/namespaces/eventhubs',
  eventHubNamespace.outputs.name,
  eventHubName
)
output consumerGroupName string = consumerGroupName
output captureIdentityId string = captureIdentity.id
