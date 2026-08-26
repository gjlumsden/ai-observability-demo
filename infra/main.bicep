targetScope = 'resourceGroup'

@description('Azure region for all demo resources.')
param location string = 'swedencentral'

@description('Azure region for the App Service web host.')
param appServiceLocation string = location

@description('Stable 6-character suffix used in demo resource names.')
param resourceSuffix string = take(uniqueString(subscription().subscriptionId, resourceGroup().id), 6)

@description('Tags applied to every resource in the demo platform.')
param tags object = {
  env: 'demo'
  owner: 'ai-observability'
  dataClassification: 'OFFICIAL'
  costCentre: 'demo'
  workload: 'ai-observability'
  demoPurpose: 'cost-attribution'
  project: 'platform-engineering'
}

@description('Current user or deployment principal object ID for role assignments.')
param principalId string = ''

@minValue(1)
@description('Monthly resource group budget amount in the billing currency.')
param monthlyBudgetAmount int = 500

@description('Optional email recipients for the budget warning and critical alerts.')
param costNotificationEmails string[] = []

@description('First day of the active budget month in UTC.')
param budgetStartDate string = utcNow('yyyy-MM-01')

@description('Future UTC start time for the daily cost export.')
param costExportStartDate string = dateTimeAdd(utcNow(), 'PT1H')

// Naming convention:
// - Hyphenated resources: ai-observability-demo-<component>-<suffix>
// - Globally-unique no-hyphen resources: aiobservability<component><suffix>

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    tags: tags
    resourceSuffix: resourceSuffix
  }
}

module storage 'modules/storage.bicep' = {
  name: 'storage'
  params: {
    location: location
    tags: tags
    resourceSuffix: resourceSuffix
    logAnalyticsWorkspaceId: monitoring.outputs.lawId
  }
}

module costManagement 'modules/cost-management.bicep' = {
  name: 'costManagement'
  params: {
    location: location
    monthlyBudgetAmount: monthlyBudgetAmount
    notificationEmails: costNotificationEmails
    budgetStartDate: budgetStartDate
    storageAccountId: storage.outputs.id
    exportStartDate: costExportStartDate
  }
}

module finOpsObservability 'modules/finops-observability.bicep' = {
  name: 'finOpsObservability'
  params: {
    location: location
    tags: tags
    resourceSuffix: resourceSuffix
    logAnalyticsWorkspaceId: monitoring.outputs.lawId
    budgetId: costManagement.outputs.budgetId
    exportId: costManagement.outputs.exportId
  }
}

module grafanaDashboard 'modules/grafana-dashboard.bicep' = {
  name: 'grafanaDashboard'
  params: {
    location: location
    tags: tags
    logAnalyticsWorkspaceId: monitoring.outputs.lawId
  }
  dependsOn: [
    finOpsObservability
  ]
}

module foundry 'modules/foundry.bicep' = {
  name: 'foundry'
  params: {
    location: location
    tags: tags
    resourceSuffix: resourceSuffix
    logAnalyticsWorkspaceId: monitoring.outputs.lawId
    appInsightsId: monitoring.outputs.appInsightsId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
  }
}

module apim 'modules/apim.bicep' = {
  name: 'apim'
  params: {
    location: location
    tags: tags
    resourceSuffix: resourceSuffix
    foundryEndpoint: foundry.outputs.foundryEndpoint
    foundryAccountName: foundry.outputs.foundryName
    appInsightsInstrumentationKey: monitoring.outputs.appInsightsInstrumentationKey
    logAnalyticsWorkspaceId: monitoring.outputs.lawId
  }
}

module apiCenter 'modules/api-center.bicep' = {
  name: 'apiCenter'
  params: {
    location: location
    tags: tags
    resourceSuffix: resourceSuffix
  }
}

module appService 'modules/app-service.bicep' = {
  name: 'appService'
  params: {
    location: appServiceLocation
    tags: tags
    resourceSuffix: resourceSuffix
    logAnalyticsWorkspaceId: monitoring.outputs.lawId
    apimBaseUrl: apim.outputs.gatewayUrl
    apimPresenterKey: apim.outputs.presenterSubscriptionKey
    entraTenantId: subscription().tenantId
    entraClientId: ''
    applicationInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
  }
}

module weatherMcp 'modules/apim-weather-mcp.bicep' = {
  name: 'weatherMcp'
  params: {
    apimName: apim.outputs.apimName
    webAppUrl: appService.outputs.webAppUrl
  }
}

module rbac 'modules/rbac.bicep' = {
  name: 'rbac'
  params: {
    location: location
    tags: tags
    resourceSuffix: resourceSuffix
    foundryName: foundry.outputs.foundryName
    currentUserPrincipalId: principalId
    apimPrincipalId: apim.outputs.apimPrincipalId
  }
}

module policy 'modules/policy.bicep' = {
  name: 'policy'
  params: {
    location: location
    allowedLocations: [
      location
      appServiceLocation
    ]
  }
}

output AZURE_RESOURCE_SUFFIX string = resourceSuffix
output AZURE_RESOURCE_GROUP string = resourceGroup().name
output AZURE_LOCATION string = location
output AZURE_APP_SERVICE_LOCATION string = appServiceLocation
output AZURE_TENANT_ID string = subscription().tenantId
output WEB_APP_URL string = appService.outputs.webAppUrl
output WEB_APP_NAME string = appService.outputs.webAppName
output APIM_NAME string = apim.outputs.apimName
output APIM_GATEWAY_URL string = apim.outputs.gatewayUrl
output OPENAI_MODEL_API_URL string = apim.outputs.openAiModelApiUrl
output CLAUDE_MODEL_API_URL string = apim.outputs.claudeModelApiUrl
output PROTECTED_CODE_API_URL string = apim.outputs.protectedCodeApiUrl
output FOUNDRY_NAME string = foundry.outputs.foundryName
output FOUNDRY_ENDPOINT string = foundry.outputs.foundryEndpoint
output CLAUDE_BASE_URL string = foundry.outputs.claudeBaseUrl
output CLAUDE_MESSAGES_ENDPOINT string = foundry.outputs.claudeMessagesEndpoint
output CLAUDE_OPUS_DEPLOYMENT string = foundry.outputs.claudeOpusDeploymentName
output API_CENTER_NAME string = apiCenter.outputs.apiCenterName
output API_CENTER_PORTAL_URL string = apiCenter.outputs.apiCenterPortalUrl
output CONTENT_SAFETY_ENDPOINT string = foundry.outputs.foundryEndpoint
output FOUNDRY_RAI_POLICY_NAME string = foundry.outputs.raiPolicyName
output STORAGE_ACCOUNT_NAME string = storage.outputs.name
output APPLICATIONINSIGHTS_CONNECTION_STRING string = monitoring.outputs.appInsightsConnectionString
output APPLICATION_INSIGHTS_ID string = monitoring.outputs.appInsightsId
output COST_BUDGET_ID string = costManagement.outputs.budgetId
output COST_EXPORT_ID string = costManagement.outputs.exportId
output FINOPS_SNAPSHOT_WORKFLOW_NAME string = finOpsObservability.outputs.workflowName
output GRAFANA_DASHBOARD_ID string = grafanaDashboard.outputs.dashboardId
output WEATHER_MCP_API_URL string = weatherMcp.outputs.mcpServerUrl
output WEATHER_MCP_BACKEND_KEY_NAMED_VALUE_ID string = weatherMcp.outputs.backendKeyNamedValueId
output WEATHER_MCP_SUBSCRIPTION_ID string = apim.outputs.weatherAgentSubscriptionId
output WEATHER_AGENT_API_URL string = apim.outputs.weatherAgentApiUrl
output WEATHER_AGENT_MODEL_NAME string = apim.outputs.weatherAgentModelName
