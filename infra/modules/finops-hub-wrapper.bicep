targetScope = 'resourceGroup'

@description('Name of the FinOps hub.')
param hubName string

@description('Name of the one workload resource group that the hub can monitor.')
param mainResourceGroupName string

@description('Azure region for the FinOps hub.')
param location string = 'swedencentral'

@description('Tags applied to the FinOps hub resources.')
param tags object = {}

@description('Enables the two managed FOCUS exports after the Data Factory identity receives access.')
param enableManagedExports bool = false

@minValue(1)
@description('Monthly budget amount for the FinOps support resource group.')
param monthlyBudgetAmount int = 100

@description('Optional email recipients for support resource-group budget notifications.')
param notificationEmails string[] = []

@description('First day of the active budget month in UTC.')
param budgetStartDate string

var mainResourceGroupId = subscriptionResourceId('Microsoft.Resources/resourceGroups', mainResourceGroupName)
var notifications = length(notificationEmails) > 0
  ? {
      warningActual: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 70
        thresholdType: 'Actual'
        contactEmails: notificationEmails
        contactGroups: []
        contactRoles: []
        locale: 'en-gb'
      }
      criticalForecasted: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: 90
        thresholdType: 'Forecasted'
        contactEmails: notificationEmails
        contactGroups: []
        contactRoles: []
        locale: 'en-gb'
      }
    }
  : {}

module finOpsHub '../vendor/finops-toolkit/v14/release/main.bicep' = {
  params: {
    hubName: hubName
    location: location
    storageSku: 'Premium_LRS'
    enableInfrastructureEncryption: false
    enablePurgeProtection: true
    enableManagedExports: enableManagedExports
    enableRecommendations: false
    dataExplorerName: ''
    fabricQueryUri: ''
    remoteHubStorageUri: ''
    scopesToMonitor: enableManagedExports
      ? [
          mainResourceGroupId
        ]
      : []
    exportRetentionInDays: 0
    ingestionRetentionInMonths: 14
    enablePublicAccess: true
    tags: union(tags, {
      workloadScope: mainResourceGroupName
    })
  }
}

resource dataFactory 'Microsoft.DataFactory/factories@2018-06-01' existing = {
  name: finOpsHub.outputs.dataFactoryName
}

resource supportActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${hubName}-alerts'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: take(replace(hubName, '-', ''), 12)
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

resource managedExportFailureAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${hubName}-managed-export-failures'
  location: 'global'
  tags: tags
  properties: {
    description: 'Detects failed FinOps hub Data Factory pipelines, including managed export orchestration.'
    severity: 1
    enabled: true
    scopes: [
      dataFactory.id
    ]
    evaluationFrequency: 'PT15M'
    windowSize: 'PT30M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.MultipleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'PipelineFailedRuns'
          criterionType: 'StaticThresholdCriterion'
          metricNamespace: 'Microsoft.DataFactory/factories'
          metricName: 'PipelineFailedRuns'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Total'
          skipMetricValidation: false
        }
      ]
    }
    actions: [
      {
        actionGroupId: supportActionGroup.id
      }
    ]
  }
}

resource supportBudget 'Microsoft.Consumption/budgets@2024-08-01' = {
  name: '${hubName}-support-budget'
  properties: {
    amount: monthlyBudgetAmount
    category: 'Cost'
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: budgetStartDate
    }
    notifications: notifications
  }
}

output dataFactoryName string = finOpsHub.outputs.dataFactoryName
output dataFactoryPrincipalId string = finOpsHub.outputs.managedIdentityId
output hubStorageAccountId string = finOpsHub.outputs.storageAccountId
output hubStorageAccountName string = finOpsHub.outputs.storageAccountName
output hubStorageUrl string = finOpsHub.outputs.storageUrlForPowerBI
output monitoredResourceGroupId string = mainResourceGroupId
output managedExportsEnabled bool = enableManagedExports
output supportBudgetId string = supportBudget.id
output managedExportFailureAlertId string = managedExportFailureAlert.id
