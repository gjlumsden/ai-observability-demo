targetScope = 'resourceGroup'

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

output budgetId string = monthlyBudget.id
