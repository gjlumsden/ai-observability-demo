targetScope = 'resourceGroup'

@description('Azure region for the FinOps snapshot resources.')
param location string

@description('Tags applied to the FinOps snapshot resources.')
param tags object

@description('Stable suffix used in demo resource names.')
param resourceSuffix string

@description('Resource ID of the Log Analytics workspace.')
param logAnalyticsWorkspaceId string

@description('Resource ID of the Cost Management budget.')
param budgetId string

@description('Resource ID of the Cost Management export.')
param exportId string

var cleanSuffix = toLower(replace(resourceSuffix, '-', ''))
var workflowName = 'ai-observability-demo-finops-${cleanSuffix}'
var dceName = 'ai-observability-demo-dce-${cleanSuffix}'
var dcrName = 'ai-observability-demo-dcr-${cleanSuffix}'
var costTableName = 'AIObservabilityCostDaily_CL'
var stateTableName = 'AIObservabilityFinOpsState_CL'
var inventoryTableName = 'AIObservabilityResourceInventory_CL'
var costStream = 'Custom-${costTableName}'
var stateStream = 'Custom-${stateTableName}'
var inventoryStream = 'Custom-${inventoryTableName}'
var resourceManagerEndpoint = environment().resourceManager
var costManagementReaderRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '72fafb9e-0641-4937-9268-a91bfd8191a3'
)
var readerRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'acdd72a7-3385-48ef-bd42-f606fba81ae7'
)
var monitoringMetricsPublisherRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '3913510d-42f4-4e42-8a64-420c390055eb'
)

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: last(split(logAnalyticsWorkspaceId, '/'))
}

resource costTable 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: workspace
  name: costTableName
  properties: {
    plan: 'Analytics'
    retentionInDays: 30
    schema: {
      name: costTableName
      displayName: 'AI Observability daily actual cost'
      description: 'Daily Cost Management actual-cost aggregates for Grafana reconciliation.'
      columns: [
        { name: 'TimeGenerated', type: 'dateTime' }
        { name: 'SnapshotId', type: 'string' }
        { name: 'UsageDate', type: 'dateTime' }
        { name: 'ServiceName', type: 'string' }
        { name: 'ActualCost', type: 'real' }
        { name: 'Currency', type: 'string' }
        { name: 'Source', type: 'string' }
      ]
    }
  }
}

resource stateTable 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: workspace
  name: stateTableName
  properties: {
    plan: 'Analytics'
    retentionInDays: 30
    schema: {
      name: stateTableName
      displayName: 'AI Observability FinOps state'
      description: 'Budget and Cost Management export state for the AI Observability Demo.'
      columns: [
        { name: 'TimeGenerated', type: 'dateTime' }
        { name: 'SnapshotId', type: 'string' }
        { name: 'BudgetName', type: 'string' }
        { name: 'BudgetAmount', type: 'real' }
        { name: 'CurrentSpend', type: 'real' }
        { name: 'Currency', type: 'string' }
        { name: 'PercentConsumed', type: 'real' }
        { name: 'NotificationRecipientsConfigured', type: 'boolean' }
        { name: 'ExportName', type: 'string' }
        { name: 'ExportScheduleStatus', type: 'string' }
        { name: 'ExportLastRunStatus', type: 'string' }
        { name: 'ExportLastRunTime', type: 'dateTime' }
        { name: 'ExportManifestPath', type: 'string' }
        { name: 'ExportFormat', type: 'string' }
        { name: 'ExportCompression', type: 'string' }
        { name: 'ExportPartitioned', type: 'boolean' }
        { name: 'ExportContainer', type: 'string' }
        { name: 'ExportRootFolder', type: 'string' }
      ]
    }
  }
}

resource inventoryTable 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: workspace
  name: inventoryTableName
  properties: {
    plan: 'Analytics'
    retentionInDays: 30
    schema: {
      name: inventoryTableName
      displayName: 'AI Observability resource inventory'
      description: 'Resource-group inventory captured with the FinOps snapshot.'
      columns: [
        { name: 'TimeGenerated', type: 'dateTime' }
        { name: 'SnapshotId', type: 'string' }
        { name: 'ResourceId', type: 'string' }
        { name: 'ResourceName', type: 'string' }
        { name: 'ResourceType', type: 'string' }
        { name: 'Location', type: 'string' }
        { name: 'Tags', type: 'dynamic' }
      ]
    }
  }
}

resource dataCollectionEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dceName
  location: location
  tags: tags
  properties: {
    description: 'Logs ingestion endpoint for AI Observability FinOps snapshots.'
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  tags: tags
  kind: 'Direct'
  properties: {
    description: 'Routes AI Observability cost, budget, export, and inventory snapshots to Log Analytics.'
    dataCollectionEndpointId: dataCollectionEndpoint.id
    streamDeclarations: {
      '${costStream}': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'SnapshotId', type: 'string' }
          { name: 'UsageDate', type: 'datetime' }
          { name: 'ServiceName', type: 'string' }
          { name: 'ActualCost', type: 'real' }
          { name: 'Currency', type: 'string' }
          { name: 'Source', type: 'string' }
        ]
      }
      '${stateStream}': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'SnapshotId', type: 'string' }
          { name: 'BudgetName', type: 'string' }
          { name: 'BudgetAmount', type: 'real' }
          { name: 'CurrentSpend', type: 'real' }
          { name: 'Currency', type: 'string' }
          { name: 'PercentConsumed', type: 'real' }
          { name: 'NotificationRecipientsConfigured', type: 'boolean' }
          { name: 'ExportName', type: 'string' }
          { name: 'ExportScheduleStatus', type: 'string' }
          { name: 'ExportLastRunStatus', type: 'string' }
          { name: 'ExportLastRunTime', type: 'datetime' }
          { name: 'ExportManifestPath', type: 'string' }
          { name: 'ExportFormat', type: 'string' }
          { name: 'ExportCompression', type: 'string' }
          { name: 'ExportPartitioned', type: 'boolean' }
          { name: 'ExportContainer', type: 'string' }
          { name: 'ExportRootFolder', type: 'string' }
        ]
      }
      '${inventoryStream}': {
        columns: [
          { name: 'TimeGenerated', type: 'datetime' }
          { name: 'SnapshotId', type: 'string' }
          { name: 'ResourceId', type: 'string' }
          { name: 'ResourceName', type: 'string' }
          { name: 'ResourceType', type: 'string' }
          { name: 'Location', type: 'string' }
          { name: 'Tags', type: 'dynamic' }
        ]
      }
    }
    destinations: {
      logAnalytics: [
        {
          name: 'aiObservabilityWorkspace'
          workspaceResourceId: workspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: [costStream]
        destinations: ['aiObservabilityWorkspace']
        transformKql: 'source'
        outputStream: costStream
      }
      {
        streams: [stateStream]
        destinations: ['aiObservabilityWorkspace']
        transformKql: 'source'
        outputStream: stateStream
      }
      {
        streams: [inventoryStream]
        destinations: ['aiObservabilityWorkspace']
        transformKql: 'source'
        outputStream: inventoryStream
      }
    ]
  }
  dependsOn: [
    costTable
    stateTable
    inventoryTable
  ]
}

resource snapshotWorkflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name: workflowName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {}
      triggers: {
        Daily: {
          type: 'Recurrence'
          recurrence: {
            frequency: 'Day'
            interval: 1
            timeZone: 'UTC'
            schedule: {
              hours: [4]
              minutes: [0]
            }
          }
        }
      }
      actions: {
        Query_actual_cost: {
          type: 'Http'
          inputs: {
            method: 'POST'
            uri: uri(resourceManagerEndpoint, '${resourceGroup().id}/providers/Microsoft.CostManagement/query?api-version=2025-03-01')
            headers: {
              'Content-Type': 'application/json'
            }
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: environment().resourceManager
            }
            retryPolicy: {
              type: 'exponential'
              count: 4
              interval: 'PT30S'
              minimumInterval: 'PT30S'
              maximumInterval: 'PT5M'
            }
            body: {
              type: 'ActualCost'
              timeframe: 'MonthToDate'
              dataset: {
                granularity: 'Daily'
                aggregation: {
                  totalCost: {
                    name: 'Cost'
                    function: 'Sum'
                  }
                }
                grouping: [
                  {
                    type: 'Dimension'
                    name: 'ServiceName'
                  }
                ]
              }
            }
          }
          runAfter: {}
        }
        Shape_cost_rows: {
          type: 'Select'
          inputs: {
            from: '@body(\'Query_actual_cost\')?[\'properties\']?[\'rows\']'
            select: {
              TimeGenerated: '@utcNow()'
              SnapshotId: '@workflow().run.name'
              UsageDate: '@concat(substring(string(item()[1]), 0, 4), \'-\', substring(string(item()[1]), 4, 2), \'-\', substring(string(item()[1]), 6, 2), \'T00:00:00Z\')'
              ServiceName: '@string(item()[2])'
              ActualCost: '@float(item()[0])'
              Currency: '@string(item()[3])'
              Source: 'CostManagementQuery'
            }
          }
          runAfter: {
            Query_actual_cost: ['Succeeded']
          }
        }
        Ingest_cost_rows: {
          type: 'Http'
          inputs: {
            method: 'POST'
            uri: '${dataCollectionEndpoint.properties.logsIngestion.endpoint}/dataCollectionRules/${dataCollectionRule.properties.immutableId}/streams/${costStream}?api-version=2023-01-01'
            headers: {
              'Content-Type': 'application/json'
            }
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: 'https://monitor.azure.com/'
            }
            retryPolicy: {
              type: 'exponential'
              count: 4
              interval: 'PT30S'
              minimumInterval: 'PT30S'
              maximumInterval: 'PT5M'
            }
            body: '@body(\'Shape_cost_rows\')'
          }
          runAfter: {
            Shape_cost_rows: ['Succeeded']
          }
        }
        Get_budget: {
          type: 'Http'
          inputs: {
            method: 'GET'
            uri: uri(resourceManagerEndpoint, '${budgetId}?api-version=2024-08-01')
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: environment().resourceManager
            }
            retryPolicy: {
              type: 'exponential'
              count: 4
              interval: 'PT30S'
              minimumInterval: 'PT30S'
              maximumInterval: 'PT5M'
            }
          }
          runAfter: {}
        }
        Get_export: {
          type: 'Http'
          inputs: {
            method: 'GET'
            uri: uri(resourceManagerEndpoint, '${exportId}?api-version=2025-03-01')
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: environment().resourceManager
            }
            retryPolicy: {
              type: 'exponential'
              count: 4
              interval: 'PT30S'
              minimumInterval: 'PT30S'
              maximumInterval: 'PT5M'
            }
          }
          runAfter: {}
        }
        Get_export_history: {
          type: 'Http'
          inputs: {
            method: 'GET'
            uri: uri(resourceManagerEndpoint, '${exportId}/runHistory?api-version=2025-03-01')
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: environment().resourceManager
            }
            retryPolicy: {
              type: 'exponential'
              count: 4
              interval: 'PT30S'
              minimumInterval: 'PT30S'
              maximumInterval: 'PT5M'
            }
          }
          runAfter: {}
        }
        Shape_export_history: {
          type: 'Select'
          inputs: {
            from: '@body(\'Get_export_history\')?[\'value\']'
            select: {
              Status: '@item()?[\'properties\']?[\'status\']'
              ProcessingEndTime: '@coalesce(item()?[\'properties\']?[\'processingEndTime\'], item()?[\'properties\']?[\'submittedTime\'])'
              ManifestFile: '@item()?[\'properties\']?[\'manifestFile\']'
            }
          }
          runAfter: {
            Get_export_history: ['Succeeded']
          }
        }
        Shape_finops_state: {
          type: 'Compose'
          inputs: [
            {
              TimeGenerated: '@utcNow()'
              SnapshotId: '@workflow().run.name'
              BudgetName: '@body(\'Get_budget\')?[\'name\']'
              BudgetAmount: '@float(body(\'Get_budget\')?[\'properties\']?[\'amount\'])'
              CurrentSpend: '@float(body(\'Get_budget\')?[\'properties\']?[\'currentSpend\']?[\'amount\'])'
              Currency: '@string(body(\'Get_budget\')?[\'properties\']?[\'currentSpend\']?[\'unit\'])'
              PercentConsumed: '@if(greater(float(body(\'Get_budget\')?[\'properties\']?[\'amount\']), 0), mul(div(float(body(\'Get_budget\')?[\'properties\']?[\'currentSpend\']?[\'amount\']), float(body(\'Get_budget\')?[\'properties\']?[\'amount\'])), 100), 0)'
              NotificationRecipientsConfigured: '@not(empty(body(\'Get_budget\')?[\'properties\']?[\'notifications\']))'
              ExportName: '@body(\'Get_export\')?[\'name\']'
              ExportScheduleStatus: '@body(\'Get_export\')?[\'properties\']?[\'schedule\']?[\'status\']'
              ExportLastRunStatus: '@if(empty(body(\'Shape_export_history\')), \'NotRun\', last(sort(body(\'Shape_export_history\'), \'ProcessingEndTime\'))?[\'Status\'])'
              ExportLastRunTime: '@if(empty(body(\'Shape_export_history\')), null, last(sort(body(\'Shape_export_history\'), \'ProcessingEndTime\'))?[\'ProcessingEndTime\'])'
              ExportManifestPath: '@if(empty(body(\'Shape_export_history\')), \'\', last(sort(body(\'Shape_export_history\'), \'ProcessingEndTime\'))?[\'ManifestFile\'])'
              ExportFormat: '@body(\'Get_export\')?[\'properties\']?[\'format\']'
              ExportCompression: '@body(\'Get_export\')?[\'properties\']?[\'compressionMode\']'
              ExportPartitioned: '@bool(body(\'Get_export\')?[\'properties\']?[\'partitionData\'])'
              ExportContainer: '@body(\'Get_export\')?[\'properties\']?[\'deliveryInfo\']?[\'destination\']?[\'container\']'
              ExportRootFolder: '@body(\'Get_export\')?[\'properties\']?[\'deliveryInfo\']?[\'destination\']?[\'rootFolderPath\']'
            }
          ]
          runAfter: {
            Get_budget: ['Succeeded']
            Get_export: ['Succeeded']
            Shape_export_history: ['Succeeded']
          }
        }
        Ingest_finops_state: {
          type: 'Http'
          inputs: {
            method: 'POST'
            uri: '${dataCollectionEndpoint.properties.logsIngestion.endpoint}/dataCollectionRules/${dataCollectionRule.properties.immutableId}/streams/${stateStream}?api-version=2023-01-01'
            headers: {
              'Content-Type': 'application/json'
            }
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: 'https://monitor.azure.com/'
            }
            retryPolicy: {
              type: 'exponential'
              count: 4
              interval: 'PT30S'
              minimumInterval: 'PT30S'
              maximumInterval: 'PT5M'
            }
            body: '@outputs(\'Shape_finops_state\')'
          }
          runAfter: {
            Shape_finops_state: ['Succeeded']
          }
        }
        Get_resource_inventory: {
          type: 'Http'
          inputs: {
            method: 'GET'
            uri: uri(resourceManagerEndpoint, '${resourceGroup().id}/resources?api-version=2021-04-01')
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: environment().resourceManager
            }
            retryPolicy: {
              type: 'exponential'
              count: 4
              interval: 'PT30S'
              minimumInterval: 'PT30S'
              maximumInterval: 'PT5M'
            }
          }
          runAfter: {}
        }
        Shape_resource_inventory: {
          type: 'Select'
          inputs: {
            from: '@body(\'Get_resource_inventory\')?[\'value\']'
            select: {
              TimeGenerated: '@utcNow()'
              SnapshotId: '@workflow().run.name'
              ResourceId: '@item()?[\'id\']'
              ResourceName: '@item()?[\'name\']'
              ResourceType: '@item()?[\'type\']'
              Location: '@coalesce(item()?[\'location\'], \'global\')'
              Tags: '@coalesce(item()?[\'tags\'], json(\'{}\'))'
            }
          }
          runAfter: {
            Get_resource_inventory: ['Succeeded']
          }
        }
        Ingest_resource_inventory: {
          type: 'Http'
          inputs: {
            method: 'POST'
            uri: '${dataCollectionEndpoint.properties.logsIngestion.endpoint}/dataCollectionRules/${dataCollectionRule.properties.immutableId}/streams/${inventoryStream}?api-version=2023-01-01'
            headers: {
              'Content-Type': 'application/json'
            }
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: 'https://monitor.azure.com/'
            }
            retryPolicy: {
              type: 'exponential'
              count: 4
              interval: 'PT30S'
              minimumInterval: 'PT30S'
              maximumInterval: 'PT5M'
            }
            body: '@body(\'Shape_resource_inventory\')'
          }
          runAfter: {
            Shape_resource_inventory: ['Succeeded']
          }
        }
      }
      outputs: {}
    }
    parameters: {}
  }
}

resource costReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, snapshotWorkflow.name, costManagementReaderRoleId)
  properties: {
    roleDefinitionId: costManagementReaderRoleId
    principalId: snapshotWorkflow.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource resourceReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, snapshotWorkflow.name, readerRoleId)
  properties: {
    roleDefinitionId: readerRoleId
    principalId: snapshotWorkflow.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource ingestionPublisherAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dataCollectionRule.id, snapshotWorkflow.name, monitoringMetricsPublisherRoleId)
  scope: dataCollectionRule
  properties: {
    roleDefinitionId: monitoringMetricsPublisherRoleId
    principalId: snapshotWorkflow.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output workflowId string = snapshotWorkflow.id
output workflowName string = snapshotWorkflow.name
output dataCollectionRuleId string = dataCollectionRule.id
output costTableName string = costTable.name
output stateTableName string = stateTable.name
output inventoryTableName string = inventoryTable.name
