targetScope = 'resourceGroup'

@description('Azure region for regional alert resources.')
param location string

@description('Tags applied to alert resources.')
param tags object

@description('Stable suffix used in resource names.')
param resourceSuffix string

@description('Optional email recipients for usage pipeline alerts.')
param notificationEmails string[] = []

@description('Resource ID of the Log Analytics workspace.')
param logAnalyticsWorkspaceId string

@description('Resource ID of the Event Hubs namespace.')
param eventHubNamespaceId string

var cleanSuffix = toLower(replace(resourceSuffix, '-', ''))
var workloadResourceGroupId = resourceGroup().id
var foundryResourceId = resourceId(
  'Microsoft.CognitiveServices/accounts',
  'ai-observability-demo-foundry-${cleanSuffix}'
)
var functionAppName = take('aiobs-usage-func-${cleanSuffix}', 60)
var usageStorageAccountName = take('aiobsusage${cleanSuffix}', 24)
var storageBlobServiceId = resourceId(
  'Microsoft.Storage/storageAccounts/blobServices',
  usageStorageAccountName,
  'default'
)
var actionGroupName = 'ai-observability-usage-alerts-${cleanSuffix}'
var actionGroupId = resourceId('Microsoft.Insights/actionGroups', actionGroupName)
var alertActions = {
  actionGroups: [
    actionGroupId
  ]
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  location: 'global'
  tags: tags
  properties: {
    groupShortName: take('aiusage${cleanSuffix}', 12)
    enabled: true
    emailReceivers: [
      for (email, index) in notificationEmails: {
        name: 'email-${index}'
        emailAddress: email
        useCommonAlertSchema: true
      }
    ]
  }
}

resource eventHubCaptureFailureAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'ai-observability-event-hub-capture-${cleanSuffix}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Detects Event Hubs server errors that can block Capture.'
    severity: 1
    enabled: true
    scopes: [
      eventHubNamespaceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'EventHubServerErrors'
          criterionType: 'StaticThresholdCriterion'
          metricNamespace: 'Microsoft.EventHub/namespaces'
          metricName: 'ServerErrors'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Total'
          skipMetricValidation: false
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

resource eventHubCaptureBacklogAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'ai-observability-event-hub-backlog-${cleanSuffix}'
  location: 'global'
  tags: tags
  properties: {
    description: 'Detects a growing Event Hubs Capture backlog.'
    severity: 1
    enabled: true
    scopes: [
      eventHubNamespaceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'CaptureBacklog'
          criterionType: 'StaticThresholdCriterion'
          metricNamespace: 'Microsoft.EventHub/namespaces'
          metricName: 'CaptureBacklog'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Maximum'
          skipMetricValidation: false
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

resource functionFailureAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'ai-observability-function-failures-${cleanSuffix}'
  location: location
  tags: tags
  properties: {
    displayName: 'AI usage processor failures'
    description: 'Detects unhandled Function App exceptions.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    targetResourceTypes: [
      'Microsoft.OperationalInsights/workspaces'
    ]
    criteria: {
      allOf: [
        {
          query: 'AppExceptions | where TimeGenerated > ago(15m) | where AppRoleName == "${functionAppName}"'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: alertActions
  }
}

resource quarantineGrowthAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'ai-observability-quarantine-growth-${cleanSuffix}'
  location: location
  tags: tags
  properties: {
    displayName: 'AI usage quarantine growth'
    description: 'Detects new malformed usage records in the quarantine container.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT30M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    targetResourceTypes: [
      'Microsoft.OperationalInsights/workspaces'
    ]
    criteria: {
      allOf: [
        {
          query: 'StorageBlobLogs | where TimeGenerated > ago(30m) | where _ResourceId =~ "${storageBlobServiceId}" | where Uri has "/quarantine/" and OperationName in ("PutBlob", "PutBlockList")'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: alertActions
  }
}

resource ingestionErrorAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'ai-observability-dcr-errors-${cleanSuffix}'
  location: location
  tags: tags
  properties: {
    displayName: 'AI usage DCR ingestion errors'
    description: 'Detects processor errors from the Logs Ingestion API.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    targetResourceTypes: [
      'Microsoft.OperationalInsights/workspaces'
    ]
    criteria: {
      allOf: [
        {
          query: 'AppTraces | where TimeGenerated > ago(15m) | where AppRoleName == "${functionAppName}" and SeverityLevel >= 3 and Message has_any ("DCR", "Logs Ingestion")'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: alertActions
  }
}

resource staleUsageAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'ai-observability-usage-stale-${cleanSuffix}'
  location: location
  tags: tags
  properties: {
    displayName: 'AI usage data is stale'
    description: 'Detects more than 30 minutes without a usage record.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT30M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    targetResourceTypes: [
      'Microsoft.OperationalInsights/workspaces'
    ]
    criteria: {
      allOf: [
        {
          query: 'union (AIRequestUsage_CL | where ResourceGroupId =~ "${workloadResourceGroupId}" and ModelResourceId =~ "${foundryResourceId}" | summarize LastSeen=max(TimeGenerated)), (print LastSeen=datetime(1970-01-01)) | summarize LastSeen=max(LastSeen) | extend AgeMinutes=datetime_diff("minute", now(), LastSeen) | project AgeMinutes'
          metricMeasureColumn: 'AgeMinutes'
          timeAggregation: 'Maximum'
          operator: 'GreaterThan'
          threshold: 30
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: alertActions
  }
}

resource missingRateAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'ai-observability-missing-rates-${cleanSuffix}'
  location: location
  tags: tags
  properties: {
    displayName: 'AI usage rate is missing'
    description: 'Detects usage rows that have no applicable rate-card entry.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT30M'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    targetResourceTypes: [
      'Microsoft.OperationalInsights/workspaces'
    ]
    criteria: {
      allOf: [
        {
          query: 'AIRequestUsage_CL | where TimeGenerated > ago(30m) | where ResourceGroupId =~ "${workloadResourceGroupId}" and ModelResourceId =~ "${foundryResourceId}" | where isempty(RateCardVersionId) or RateCardVersionId == "no-rate" or isnull(EstimatedCost)'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: alertActions
  }
}

resource allocationStaleAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'ai-observability-focus-stale-${cleanSuffix}'
  location: location
  tags: tags
  properties: {
    displayName: 'FinOps FOCUS allocation data is stale'
    description: 'Detects more than 36 hours without a successful allocation record.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1H'
    windowSize: 'PT1H'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    targetResourceTypes: [
      'Microsoft.OperationalInsights/workspaces'
    ]
    criteria: {
      allOf: [
        {
          query: 'union (AICostAllocation_CL | where SourceScope =~ "${workloadResourceGroupId}" and IncludedInWorkloadTotal == true | summarize LastSeen=max(TimeGenerated)), (print LastSeen=datetime(1970-01-01)) | summarize LastSeen=max(LastSeen) | extend AgeHours=datetime_diff("hour", now(), LastSeen) | project AgeHours'
          metricMeasureColumn: 'AgeHours'
          timeAggregation: 'Maximum'
          operator: 'GreaterThan'
          threshold: 36
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: alertActions
  }
}

resource reconciliationDriftAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'ai-observability-reconciliation-drift-${cleanSuffix}'
  location: location
  tags: tags
  properties: {
    displayName: 'AI cost allocation reconciliation drift'
    description: 'Detects allocation runs whose allocated and unallocated values do not match the source cost.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT30M'
    windowSize: 'PT1H'
    scopes: [
      logAnalyticsWorkspaceId
    ]
    targetResourceTypes: [
      'Microsoft.OperationalInsights/workspaces'
    ]
    criteria: {
      allOf: [
        {
          query: 'let ScopedRows = AICostAllocation_CL | where SourceScope =~ "${workloadResourceGroupId}" and IncludedInWorkloadTotal == true; let LatestRuns = ScopedRows | summarize arg_max(TimeGenerated, RunId) by SourcePath | project SourcePath, RunId; LatestRuns | join kind=inner (ScopedRows) on SourcePath, RunId | where TimeGenerated > ago(1h) | summarize SourceBilledCost=take_any(SourceBilledCost), SourceEffectiveCost=take_any(SourceEffectiveCost), AllocatedBilledCost=sum(AllocatedBilledCost), AllocatedEffectiveCost=sum(AllocatedEffectiveCost), UnallocatedBilledCost=sum(UnallocatedBilledCost), UnallocatedEffectiveCost=sum(UnallocatedEffectiveCost) by RunId, SourcePath, SourceETag, ChargePeriodStart, ChargePeriodEnd, Provider, MeterId, MeterName, ResourceId | where (isnotnull(SourceBilledCost) and abs(SourceBilledCost-AllocatedBilledCost-UnallocatedBilledCost) > 0.01) or (isnotnull(SourceEffectiveCost) and abs(SourceEffectiveCost-AllocatedEffectiveCost-UnallocatedEffectiveCost) > 0.01)'
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    autoMitigate: true
    actions: alertActions
  }
}

output actionGroupId string = actionGroup.id
output eventHubCaptureFailureAlertId string = eventHubCaptureFailureAlert.id
output eventHubCaptureBacklogAlertId string = eventHubCaptureBacklogAlert.id
