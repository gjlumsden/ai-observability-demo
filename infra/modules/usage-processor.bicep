targetScope = 'resourceGroup'

@description('Azure region for the usage processor.')
param location string

@description('Tags applied to the usage processor.')
param tags object

@description('Stable suffix used in resource names.')
param resourceSuffix string

@description('Exact ARM ID of the demo resource group.')
param workloadResourceGroupId string

@description('Exact ARM IDs of model resources that can contribute usage.')
param workloadModelResourceIds string[]

@description('Name of the usage storage account.')
param storageAccountName string

@description('Blob endpoint for the usage storage account.')
param storageBlobEndpoint string

@description('Queue endpoint for the usage storage account.')
param storageQueueEndpoint string

@description('Table endpoint for the usage storage account.')
param storageTableEndpoint string

@description('Name of the blob container used for Function package deployment.')
param deploymentContainerName string

@description('Name of the blob container used for malformed usage events.')
param quarantineContainerName string

@description('Name of the table used for processor ETag state.')
param processorStateTableName string

@description('Name of the Event Hubs namespace.')
param eventHubNamespaceName string

@description('Fully qualified Event Hubs namespace.')
param eventHubNamespaceFullyQualifiedName string

@description('Name of the usage event hub.')
param eventHubName string

@description('Name of the processor consumer group.')
param eventHubConsumerGroupName string

@description('Name of the direct data collection rule.')
param dataCollectionRuleName string

@description('Immutable ID of the direct data collection rule.')
param dataCollectionRuleImmutableId string

@description('Public logs ingestion endpoint of the direct data collection rule.')
param logsIngestionEndpoint string

@description('Stream name for AI request usage.')
param usageStreamName string

@description('Stream name for AI cost allocation.')
param allocationStreamName string

@description('Name of the blob container that stores Event Hubs Capture archives.')
param captureContainerName string

@description('Name of the Log Analytics workspace.')
param logAnalyticsWorkspaceName string

@description('Name of the Application Insights component.')
param applicationInsightsName string

@description('Application Insights connection string.')
@secure()
param applicationInsightsConnectionString string

var cleanSuffix = toLower(replace(resourceSuffix, '-', ''))
var functionAppName = take('aiobs-usage-func-${cleanSuffix}', 60)
var planName = 'aiobs-usage-fc-${cleanSuffix}'
var identityName = 'aiobs-usage-processor-${cleanSuffix}'
var storageBlobDataOwnerRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
)
var storageQueueDataContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
)
var storageTableDataContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
)
var eventHubsDataReceiverRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'a638d3c7-ab3a-418d-83e6-5f17a39d4fde'
)
var monitoringMetricsPublisherRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '3913510d-42f4-4e42-8a64-420c390055eb'
)
var logAnalyticsReaderRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '73c42c96-874c-492b-b04d-ab87d138a893'
)

resource processorIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' existing = {
  name: eventHubNamespaceName
}

resource usageEventHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' existing = {
  parent: eventHubNamespace
  name: eventHubName
}

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' existing = {
  name: dataCollectionRuleName
}

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource applicationInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: applicationInsightsName
}

resource blobDataOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, processorIdentity.id, storageBlobDataOwnerRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageBlobDataOwnerRoleId
    principalId: processorIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource queueDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, processorIdentity.id, storageQueueDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageQueueDataContributorRoleId
    principalId: processorIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource tableDataContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, processorIdentity.id, storageTableDataContributorRoleId)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageTableDataContributorRoleId
    principalId: processorIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource eventHubReceiver 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(usageEventHub.id, processorIdentity.id, eventHubsDataReceiverRoleId)
  scope: usageEventHub
  properties: {
    roleDefinitionId: eventHubsDataReceiverRoleId
    principalId: processorIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource dcrPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dataCollectionRule.id, processorIdentity.id, monitoringMetricsPublisherRoleId)
  scope: dataCollectionRule
  properties: {
    roleDefinitionId: monitoringMetricsPublisherRoleId
    principalId: processorIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource workspaceReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(logAnalyticsWorkspace.id, processorIdentity.id, logAnalyticsReaderRoleId)
  scope: logAnalyticsWorkspace
  properties: {
    roleDefinitionId: logAnalyticsReaderRoleId
    principalId: processorIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource applicationInsightsPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(applicationInsights.id, processorIdentity.id, monitoringMetricsPublisherRoleId)
  scope: applicationInsights
  properties: {
    roleDefinitionId: monitoringMetricsPublisherRoleId
    principalId: processorIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource flexPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: planName
  location: location
  kind: 'functionapp'
  tags: tags
  sku: {
    name: 'FC1'
    tier: 'FlexConsumption'
  }
  properties: {
    reserved: true
  }
}

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${processorIdentity.id}': {}
    }
  }
  properties: {
    serverFarmId: flexPlan.id
    httpsOnly: true
    publicNetworkAccess: 'Enabled'
    siteConfig: {
      ftpsState: 'Disabled'
      http20Enabled: true
      minTlsVersion: '1.2'
    }
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storageBlobEndpoint}${deploymentContainerName}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: processorIdentity.id
          }
        }
      }
      runtime: {
        name: 'python'
        version: '3.12'
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 100
        instanceMemoryMB: 2048
      }
    }
  }
  dependsOn: [
    blobDataOwner
    queueDataContributor
    tableDataContributor
    eventHubReceiver
    dcrPublisher
    workspaceReader
    applicationInsightsPublisher
  ]
}

resource functionAppSettings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: functionApp
  name: 'appsettings'
  properties: {
    FUNCTIONS_EXTENSION_VERSION: '~4'
    FUNCTIONS_WORKER_RUNTIME: 'python'
    AzureWebJobsStorage__accountName: storageAccount.name
    AzureWebJobsStorage__blobServiceUri: storageBlobEndpoint
    AzureWebJobsStorage__queueServiceUri: storageQueueEndpoint
    AzureWebJobsStorage__tableServiceUri: storageTableEndpoint
    AzureWebJobsStorage__credential: 'managedidentity'
    AzureWebJobsStorage__clientId: processorIdentity.properties.clientId
    AzureWebJobsSecretStorageType: 'blob'
    AIUsageEventHub__fullyQualifiedNamespace: eventHubNamespaceFullyQualifiedName
    AIUsageEventHub__credential: 'managedidentity'
    AIUsageEventHub__clientId: processorIdentity.properties.clientId
    AI_USAGE_EVENT_HUB_NAME: usageEventHub.name
    AI_USAGE_CONSUMER_GROUP: eventHubConsumerGroupName
    USAGE_STORAGE_ACCOUNT_NAME: storageAccount.name
    USAGE_STORAGE_BLOB_ENDPOINT: storageBlobEndpoint
    USAGE_STORAGE_QUEUE_ENDPOINT: storageQueueEndpoint
    USAGE_STORAGE_TABLE_ENDPOINT: storageTableEndpoint
    USAGE_CAPTURE_CONTAINER: captureContainerName
    USAGE_PROCESSOR_STATE_TABLE: processorStateTableName
    USAGE_QUARANTINE_CONTAINER: quarantineContainerName
    DCR_ENDPOINT: logsIngestionEndpoint
    DCR_IMMUTABLE_ID: dataCollectionRuleImmutableId
    DCR_USAGE_STREAM: usageStreamName
    DCR_ALLOCATION_STREAM: allocationStreamName
    WORKLOAD_RESOURCE_GROUP_ID: workloadResourceGroupId
    WORKLOAD_MODEL_RESOURCE_IDS: join(workloadModelResourceIds, ',')
    LOG_ANALYTICS_WORKSPACE_ID: logAnalyticsWorkspace.properties.customerId
    AZURE_SUBSCRIPTION_ID: subscription().subscriptionId
    APPLICATIONINSIGHTS_CONNECTION_STRING: applicationInsightsConnectionString
    APPLICATIONINSIGHTS_AUTHENTICATION_STRING: 'Authorization=AAD;ClientId=${processorIdentity.properties.clientId}'
  }
}

resource ftpBasicAuthPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: functionApp
  name: 'ftp'
  properties: {
    allow: false
  }
}

resource scmBasicAuthPolicy 'Microsoft.Web/sites/basicPublishingCredentialsPolicies@2024-04-01' = {
  parent: functionApp
  name: 'scm'
  properties: {
    allow: false
  }
}

output functionAppName string = functionApp.name
output functionAppId string = functionApp.id
output functionAppHostName string = functionApp.properties.defaultHostName
output principalId string = processorIdentity.properties.principalId
output identityClientId string = processorIdentity.properties.clientId
output identityResourceId string = processorIdentity.id
