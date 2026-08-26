targetScope = 'resourceGroup'

@description('Azure region for the Cost Management export identity.')
param location string

@minValue(1)
@description('Monthly resource group budget amount in the billing currency.')
param monthlyBudgetAmount int

@minValue(1)
@maxValue(1000)
@description('Actual-cost percentage that triggers the warning notification.')
param warningThreshold int = 70

@minValue(1)
@maxValue(1000)
@description('Actual-cost percentage that triggers the critical notification.')
param criticalThreshold int = 90

@description('Optional email recipients for budget notifications.')
param notificationEmails string[] = []

@description('First day of the budget month in UTC.')
param budgetStartDate string

@description('Resource ID of the export destination storage account.')
param storageAccountId string

@description('UTC start time for the daily cost export schedule.')
param exportStartDate string

var storageBlobDataContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
)

var notifications = length(notificationEmails) > 0
  ? {
      warningActual: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: warningThreshold
        thresholdType: 'Actual'
        contactEmails: notificationEmails
        contactGroups: []
        contactRoles: []
        locale: 'en-gb'
      }
      criticalActual: {
        enabled: true
        operator: 'GreaterThanOrEqualTo'
        threshold: criticalThreshold
        thresholdType: 'Actual'
        contactEmails: notificationEmails
        contactGroups: []
        contactRoles: []
        locale: 'en-gb'
      }
    }
  : {}

resource monthlyBudget 'Microsoft.Consumption/budgets@2024-08-01' = {
  name: 'ai-observability-demo-monthly-budget'
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

resource dailyActualCostExport 'Microsoft.CostManagement/exports@2025-03-01' = {
  name: 'ai-observability-demo-daily-actual-cost'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    exportDescription: 'Daily actual cost for the AI Observability Demo resource group.'
    format: 'Csv'
    compressionMode: 'gzip'
    partitionData: true
    dataOverwriteBehavior: 'OverwritePreviousReport'
    definition: {
      type: 'ActualCost'
      timeframe: 'MonthToDate'
      dataSet: {
        granularity: 'Daily'
      }
    }
    deliveryInfo: {
      destination: {
        type: 'AzureBlob'
        resourceId: storageAccountId
        container: 'cost-exports'
        rootFolderPath: 'daily-actual-cost'
      }
    }
    schedule: {
      status: 'Active'
      recurrence: 'Daily'
      recurrencePeriod: {
        from: exportStartDate
        to: dateTimeAdd(exportStartDate, 'P2Y')
      }
    }
  }
}

resource destinationStorage 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: last(split(storageAccountId, '/'))
}

resource exportBlobWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccountId, dailyActualCostExport.name, storageBlobDataContributorRoleId)
  scope: destinationStorage
  properties: {
    roleDefinitionId: storageBlobDataContributorRoleId
    principalId: dailyActualCostExport.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

output budgetId string = monthlyBudget.id
output exportId string = dailyActualCostExport.id
