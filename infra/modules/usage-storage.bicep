targetScope = 'resourceGroup'

@description('Azure region for the usage storage account.')
param location string

@description('Tags applied to the usage storage account.')
param tags object

@description('Stable suffix used in resource names.')
param resourceSuffix string

@description('Log Analytics workspace resource ID for diagnostics.')
param logAnalyticsWorkspaceId string

var cleanSuffix = toLower(replace(resourceSuffix, '-', ''))
var storageAccountName = take('aiobsusage${cleanSuffix}', 24)
var deploymentContainerName = 'function-releases'
var captureContainerName = 'capture'
var quarantineContainerName = 'quarantine'
var processorStateTableName = 'processorstate'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowCrossTenantReplication: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Enabled'
    supportsHttpsTrafficOnly: true
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource functionHostsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'azure-webjobs-hosts'
  properties: {
    publicAccess: 'None'
  }
}

resource functionSecretsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'azure-webjobs-secrets'
  properties: {
    publicAccess: 'None'
  }
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: deploymentContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource captureContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: captureContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource quarantineContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: quarantineContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource processorWorkQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: 'processor-work'
}

resource tableService 'Microsoft.Storage/storageAccounts/tableServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
}

resource processorStateTable 'Microsoft.Storage/storageAccounts/tableServices/tables@2023-05-01' = {
  parent: tableService
  name: processorStateTableName
}

resource lifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'delete-pseudonymous-usage-after-400-days'
          enabled: true
          type: 'Lifecycle'
          definition: {
            actions: {
              baseBlob: {
                delete: {
                  daysAfterModificationGreaterThan: 400
                }
              }
            }
            filters: {
              blobTypes: [
                'blockBlob'
              ]
              prefixMatch: [
                '${captureContainerName}/'
                '${quarantineContainerName}/'
              ]
            }
          }
        }
      ]
    }
  }
}

resource storageDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${storageAccount.name}'
  scope: storageAccount
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

resource blobDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${storageAccount.name}-blob'
  scope: blobService
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'StorageRead'
        enabled: true
      }
      {
        category: 'StorageWrite'
        enabled: true
      }
      {
        category: 'StorageDelete'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output name string = storageAccount.name
output id string = storageAccount.id
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob
output queueEndpoint string = storageAccount.properties.primaryEndpoints.queue
output tableEndpoint string = storageAccount.properties.primaryEndpoints.table
output deploymentContainerName string = deploymentContainer.name
output deploymentContainerId string = deploymentContainer.id
output captureContainerName string = captureContainer.name
output captureContainerId string = captureContainer.id
output quarantineContainerName string = quarantineContainer.name
output processorStateTableName string = processorStateTable.name
