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

@minValue(1)
@description('Monthly budget amount for the sibling FinOps support resource group.')
param finOpsMonthlyBudgetAmount int = 100

@description('Optional email recipients for the budget warning and critical alerts.')
param costNotificationEmails string[] = []

@description('First day of the active budget month in UTC.')
param budgetStartDate string = utcNow('yyyy-MM-01')

@description('A non-sensitive value that reruns the idempotent HMAC key bootstrap.')
param hmacBootstrapRunId string = utcNow('yyyyMMddHHmmss')

// Naming convention:
// - Hyphenated resources: ai-observability-demo-<component>-<suffix>
// - Globally-unique no-hyphen resources: aiobservability<component><suffix>

var usageLocation = 'swedencentral'
var finOpsResourceGroupName = take('${resourceGroup().name}-finops', 90)
var finOpsHubName = 'aiobs-hub-${resourceSuffix}'

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    tags: tags
    resourceSuffix: resourceSuffix
  }
}

module usageStorage 'modules/usage-storage.bicep' = {
  name: 'usageStorage'
  params: {
    location: usageLocation
    tags: tags
    resourceSuffix: resourceSuffix
    logAnalyticsWorkspaceId: monitoring.outputs.lawId
  }
}

module costManagement 'modules/cost-management.bicep' = {
  name: 'costManagement'
  params: {
    monthlyBudgetAmount: monthlyBudgetAmount
    notificationEmails: costNotificationEmails
    budgetStartDate: budgetStartDate
  }
}

module identityVault 'modules/identity-vault.bicep' = {
  name: 'identityVault'
  params: {
    location: usageLocation
    tags: tags
    resourceSuffix: resourceSuffix
    hmacBootstrapRunId: hmacBootstrapRunId
  }
}

module usageEventStream 'modules/usage-event-stream.bicep' = {
  name: 'usageEventStream'
  params: {
    location: usageLocation
    tags: tags
    resourceSuffix: resourceSuffix
    storageAccountName: usageStorage.outputs.name
    captureContainerName: usageStorage.outputs.captureContainerName
    logAnalyticsWorkspaceId: monitoring.outputs.lawId
  }
}

module usageObservability 'modules/usage-observability.bicep' = {
  name: 'usageObservability'
  params: {
    location: usageLocation
    tags: tags
    resourceSuffix: resourceSuffix
    logAnalyticsWorkspaceId: monitoring.outputs.lawId
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
    usageObservability
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
    eventHubNamespaceName: usageEventStream.outputs.namespaceName
    usageEventHubName: usageEventStream.outputs.eventHubName
    usageKeyVaultName: identityVault.outputs.keyVaultName
    usageHmacKeyVaultReference: identityVault.outputs.secretIdentifier
  }
}

module usageProcessor 'modules/usage-processor.bicep' = {
  name: 'usageProcessor'
  params: {
    location: usageLocation
    tags: tags
    resourceSuffix: resourceSuffix
    workloadResourceGroupId: resourceGroup().id
    workloadModelResourceIds: [
      foundry.outputs.foundryId
    ]
    storageAccountName: usageStorage.outputs.name
    storageBlobEndpoint: usageStorage.outputs.blobEndpoint
    storageQueueEndpoint: usageStorage.outputs.queueEndpoint
    storageTableEndpoint: usageStorage.outputs.tableEndpoint
    deploymentContainerName: usageStorage.outputs.deploymentContainerName
    quarantineContainerName: usageStorage.outputs.quarantineContainerName
    processorStateTableName: usageStorage.outputs.processorStateTableName
    eventHubNamespaceName: usageEventStream.outputs.namespaceName
    eventHubNamespaceFullyQualifiedName: usageEventStream.outputs.namespaceFullyQualifiedName
    eventHubName: usageEventStream.outputs.eventHubName
    eventHubConsumerGroupName: usageEventStream.outputs.consumerGroupName
    dataCollectionRuleName: usageObservability.outputs.dataCollectionRuleName
    dataCollectionRuleImmutableId: usageObservability.outputs.dataCollectionRuleImmutableId
    logsIngestionEndpoint: usageObservability.outputs.logsIngestionEndpoint
    usageStreamName: usageObservability.outputs.usageStreamName
    allocationStreamName: usageObservability.outputs.allocationStreamName
    captureContainerName: usageStorage.outputs.captureContainerName
    logAnalyticsWorkspaceName: monitoring.outputs.lawName
    applicationInsightsName: monitoring.outputs.appInsightsName
    applicationInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
  }
}

module usageAlerts 'modules/usage-alerts.bicep' = {
  name: 'usageAlerts'
  params: {
    location: usageLocation
    tags: tags
    resourceSuffix: resourceSuffix
    notificationEmails: costNotificationEmails
    logAnalyticsWorkspaceId: monitoring.outputs.lawId
    eventHubNamespaceId: usageEventStream.outputs.namespaceId
  }
  dependsOn: [
    usageProcessor
  ]
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
    allowedLocations: union(
      [
        location
        appServiceLocation
      ],
      [
        usageLocation
      ]
    )
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
output APIM_USAGE_EVENT_HUB_LOGGER_NAME string = apim.outputs.usageEventHubLoggerName
output APIM_USAGE_HMAC_NAMED_VALUE_ID string = apim.outputs.usageHmacNamedValueId
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
output STORAGE_ACCOUNT_NAME string = usageStorage.outputs.name
output USAGE_STORAGE_ACCOUNT_NAME string = usageStorage.outputs.name
output USAGE_STORAGE_ACCOUNT_ID string = usageStorage.outputs.id
output USAGE_CAPTURE_CONTAINER_NAME string = usageStorage.outputs.captureContainerName
output USAGE_QUARANTINE_CONTAINER_NAME string = usageStorage.outputs.quarantineContainerName
output USAGE_PROCESSOR_STATE_TABLE_NAME string = usageStorage.outputs.processorStateTableName
output USAGE_EVENT_HUB_NAMESPACE string = usageEventStream.outputs.namespaceName
output USAGE_EVENT_HUB_NAME string = usageEventStream.outputs.eventHubName
output USAGE_EVENT_HUB_ID string = usageEventStream.outputs.eventHubId
output USAGE_EVENT_HUB_CONSUMER_GROUP string = usageEventStream.outputs.consumerGroupName
output USAGE_KEY_VAULT_NAME string = identityVault.outputs.keyVaultName
output USAGE_HMAC_SECRET_NAME string = identityVault.outputs.secretName
output HMAC_BOOTSTRAP_ROLE_ASSIGNMENT_ID string = identityVault.outputs.bootstrapRoleAssignmentId
output USAGE_DCR_ID string = usageObservability.outputs.dataCollectionRuleId
output USAGE_DCR_IMMUTABLE_ID string = usageObservability.outputs.dataCollectionRuleImmutableId
output USAGE_DCR_ENDPOINT string = usageObservability.outputs.logsIngestionEndpoint
output USAGE_LOG_TABLE_NAME string = usageObservability.outputs.usageTableName
output COST_ALLOCATION_LOG_TABLE_NAME string = usageObservability.outputs.allocationTableName
output USAGE_PROCESSOR_FUNCTION_NAME string = usageProcessor.outputs.functionAppName
output USAGE_PROCESSOR_FUNCTION_ID string = usageProcessor.outputs.functionAppId
output USAGE_PROCESSOR_PRINCIPAL_ID string = usageProcessor.outputs.principalId
output USAGE_PROCESSOR_IDENTITY_CLIENT_ID string = usageProcessor.outputs.identityClientId
output APPLICATIONINSIGHTS_CONNECTION_STRING string = monitoring.outputs.appInsightsConnectionString
output APPLICATION_INSIGHTS_ID string = monitoring.outputs.appInsightsId
output COST_BUDGET_ID string = costManagement.outputs.budgetId
output MAIN_RESOURCE_GROUP_ID string = resourceGroup().id
output FINOPS_RESOURCE_GROUP_NAME string = finOpsResourceGroupName
output FINOPS_HUB_NAME string = finOpsHubName
output FINOPS_LOCATION string = usageLocation
output FINOPS_SUPPORT_BUDGET_AMOUNT int = finOpsMonthlyBudgetAmount
output FINOPS_BUDGET_START_DATE string = budgetStartDate
output FINOPS_NOTIFICATION_EMAILS string = join(costNotificationEmails, ';')
output GRAFANA_DASHBOARD_ID string = grafanaDashboard.outputs.dashboardId
output WEATHER_MCP_API_URL string = weatherMcp.outputs.mcpServerUrl
output WEATHER_MCP_BACKEND_KEY_NAMED_VALUE_ID string = weatherMcp.outputs.backendKeyNamedValueId
output WEATHER_MCP_SUBSCRIPTION_ID string = apim.outputs.weatherAgentSubscriptionId
output WEATHER_AGENT_API_URL string = apim.outputs.weatherAgentApiUrl
output WEATHER_AGENT_MODEL_NAME string = apim.outputs.weatherAgentModelName
