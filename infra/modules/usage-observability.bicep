targetScope = 'resourceGroup'

@description('Azure region for usage observability resources.')
param location string

@description('Tags applied to usage observability resources.')
param tags object

@description('Stable suffix used in resource names.')
param resourceSuffix string

@description('Resource ID of the target Log Analytics workspace.')
param logAnalyticsWorkspaceId string

var cleanSuffix = toLower(replace(resourceSuffix, '-', ''))
var dataCollectionRuleName = 'ai-observability-usage-dcr-${cleanSuffix}'
var usageTableName = 'AIRequestUsage_CL'
var allocationTableName = 'AICostAllocation_CL'
var usageStreamName = 'Custom-${usageTableName}'
var allocationStreamName = 'Custom-${allocationTableName}'

var usageColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'EventId', type: 'string' }
  { name: 'SchemaVersion', type: 'string' }
  { name: 'CorrelationId', type: 'string' }
  { name: 'TraceId', type: 'string' }
  { name: 'Provider', type: 'string' }
  { name: 'RequestModel', type: 'string' }
  { name: 'ResponseModel', type: 'string' }
  { name: 'DeploymentName', type: 'string' }
  { name: 'DeploymentType', type: 'string' }
  { name: 'ModelResourceId', type: 'string' }
  { name: 'ResourceGroupId', type: 'string' }
  { name: 'TeamId', type: 'string' }
  { name: 'SubjectId', type: 'string' }
  { name: 'ProjectId', type: 'string' }
  { name: 'AttributionMode', type: 'string' }
  { name: 'RequestOutcome', type: 'string' }
  { name: 'HttpStatusCode', type: 'long' }
  { name: 'LatencyMs', type: 'long' }
  { name: 'TokenQuality', type: 'string' }
  { name: 'InputTokens', type: 'long' }
  { name: 'CachedInputTokens', type: 'long' }
  { name: 'UncachedInputTokens', type: 'long' }
  { name: 'CacheWrite5mTokens', type: 'long' }
  { name: 'CacheWrite1hTokens', type: 'long' }
  { name: 'OutputTokens', type: 'long' }
  { name: 'ReasoningTokens', type: 'long' }
  { name: 'VisibleOutputTokens', type: 'long' }
  { name: 'TotalTokens', type: 'long' }
  { name: 'RawUsage', type: 'dynamic' }
  { name: 'RateCardVersionId', type: 'string' }
  { name: 'EstimatedCost', type: 'real' }
  { name: 'PricingCurrency', type: 'string' }
  { name: 'EventHubPartition', type: 'long' }
  { name: 'EventHubSequenceNumber', type: 'long' }
  { name: 'ArchivePath', type: 'string' }
]

var allocationColumns = [
  { name: 'TimeGenerated', type: 'datetime' }
  { name: 'RunId', type: 'string' }
  { name: 'AllocationVersion', type: 'string' }
  { name: 'SourceType', type: 'string' }
  { name: 'SourceScope', type: 'string' }
  { name: 'ChargePeriodStart', type: 'datetime' }
  { name: 'ChargePeriodEnd', type: 'datetime' }
  { name: 'BillingPeriodStart', type: 'datetime' }
  { name: 'BillingPeriodEnd', type: 'datetime' }
  { name: 'Provider', type: 'string' }
  { name: 'PublisherName', type: 'string' }
  { name: 'MeterId', type: 'string' }
  { name: 'MeterName', type: 'string' }
  { name: 'ResourceId', type: 'string' }
  { name: 'BillingCurrency', type: 'string' }
  { name: 'SourceQuantity', type: 'real' }
  { name: 'SourceUnit', type: 'string' }
  { name: 'SourceBilledCost', type: 'real' }
  { name: 'SourceEffectiveCost', type: 'real' }
  { name: 'TeamId', type: 'string' }
  { name: 'SubjectId', type: 'string' }
  { name: 'AllocationBasis', type: 'string' }
  { name: 'AllocationWeight', type: 'real' }
  { name: 'AllocationRatio', type: 'real' }
  { name: 'AllocatedBilledCost', type: 'real' }
  { name: 'AllocatedEffectiveCost', type: 'real' }
  { name: 'UnallocatedBilledCost', type: 'real' }
  { name: 'UnallocatedEffectiveCost', type: 'real' }
  { name: 'AttributionStatus', type: 'string' }
  { name: 'IncludedInWorkloadTotal', type: 'boolean' }
  { name: 'RateCardVersionId', type: 'string' }
  { name: 'UsageSnapshotId', type: 'string' }
  { name: 'SourcePath', type: 'string' }
  { name: 'SourceETag', type: 'string' }
]

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: last(split(logAnalyticsWorkspaceId, '/'))
}

resource usageTable 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: workspace
  name: usageTableName
  properties: {
    plan: 'Analytics'
    retentionInDays: 120
    totalRetentionInDays: 120
    schema: {
      name: usageTableName
      displayName: 'AI request usage'
      description: 'Pseudonymous provider usage records emitted by API Management.'
      columns: usageColumns
    }
  }
}

resource allocationTable 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: workspace
  name: allocationTableName
  properties: {
    plan: 'Analytics'
    retentionInDays: 400
    totalRetentionInDays: 400
    schema: {
      name: allocationTableName
      displayName: 'AI cost allocation'
      description: 'Append-only FOCUS allocation runs and external cost context.'
      columns: allocationColumns
    }
  }
}

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dataCollectionRuleName
  location: location
  tags: tags
  kind: 'Direct'
  properties: {
    description: 'Routes pseudonymous AI usage and cost allocation records to Log Analytics.'
    streamDeclarations: {
      '${usageStreamName}': {
        columns: usageColumns
      }
      '${allocationStreamName}': {
        columns: allocationColumns
      }
    }
    destinations: {
      logAnalytics: [
        {
          name: 'usageWorkspace'
          workspaceResourceId: workspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          usageStreamName
        ]
        destinations: [
          'usageWorkspace'
        ]
        transformKql: 'source'
        outputStream: usageStreamName
      }
      {
        streams: [
          allocationStreamName
        ]
        destinations: [
          'usageWorkspace'
        ]
        transformKql: 'source'
        outputStream: allocationStreamName
      }
    ]
  }
  dependsOn: [
    usageTable
    allocationTable
  ]
}

output dataCollectionRuleId string = dataCollectionRule.id
output dataCollectionRuleName string = dataCollectionRule.name
output dataCollectionRuleImmutableId string = dataCollectionRule.properties.immutableId
output logsIngestionEndpoint string = dataCollectionRule.properties.endpoints.logsIngestion
output usageStreamName string = usageStreamName
output allocationStreamName string = allocationStreamName
output usageTableName string = usageTable.name
output allocationTableName string = allocationTable.name
