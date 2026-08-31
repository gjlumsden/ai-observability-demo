targetScope = 'resourceGroup'

@description('Azure region for the Azure Monitor Grafana dashboard.')
param location string

@description('Tags applied to the Grafana dashboard.')
param tags object

@description('Resource ID of the Log Analytics workspace queried by the dashboard.')
param logAnalyticsWorkspaceId string

var logAnalyticsWorkspaceName = last(split(logAnalyticsWorkspaceId, '/'))
var cleanSuffix = toLower(replace(logAnalyticsWorkspaceName, 'ai-observability-demo-law-', ''))
var usageLocation = 'swedencentral'
var businessDashboardName = 'AI-Observability-and-Cost'
var operationsDashboardName = 'Attribution-Pipeline-Ops'
var workloadResourceGroupId = resourceGroup().id
var foundryResourceId = resourceId(
  'Microsoft.CognitiveServices/accounts',
  'ai-observability-demo-foundry-${cleanSuffix}'
)
var apimResourceId = resourceId(
  'Microsoft.ApiManagement/service',
  'ai-observability-demo-apim-${cleanSuffix}'
)
var eventHubNamespaceName = take('aiobs-usage-eh-${cleanSuffix}', 50)
var eventHubNamespaceId = resourceId('Microsoft.EventHub/namespaces', eventHubNamespaceName)
var functionAppName = take('aiobs-usage-func-${cleanSuffix}', 60)
var usageStorageAccountName = take('aiobsusage${cleanSuffix}', 24)
var finOpsResourceGroupName = take('${resourceGroup().name}-finops', 90)
var finOpsResourceGroupId = subscriptionResourceId(
  'Microsoft.Resources/resourceGroups',
  finOpsResourceGroupName
)
var finOpsHubName = 'aiobs-hub-${cleanSuffix}'
var finOpsSuffix = uniqueString(finOpsHubName, finOpsResourceGroupId)
var finOpsDataFactoryBaseName = '${replace(finOpsHubName, '_', '-')}-engine'
var finOpsDataFactoryName = replace(
  '${take(finOpsDataFactoryBaseName, 63 - length(finOpsSuffix) - 1)}-${finOpsSuffix}',
  '--',
  '-'
)
var storageBlobServiceId = resourceId(
  'Microsoft.Storage/storageAccounts/blobServices',
  usageStorageAccountName,
  'default'
)

var dashboardBundleSource = loadTextContent('../dashboards/grafana-dashboard.json')
var dashboardBundleWithWorkspace = replace(
  dashboardBundleSource,
  '__WORKSPACE_RESOURCE_ID__',
  logAnalyticsWorkspaceId
)
var dashboardBundleWithResourceGroup = replace(
  dashboardBundleWithWorkspace,
  '__RESOURCE_GROUP_ID__',
  workloadResourceGroupId
)
var dashboardBundleWithFoundry = replace(
  dashboardBundleWithResourceGroup,
  '__FOUNDRY_RESOURCE_ID__',
  foundryResourceId
)
var dashboardBundleWithApim = replace(dashboardBundleWithFoundry, '__APIM_RESOURCE_ID__', apimResourceId)
var dashboardBundleWithSubscription = replace(
  dashboardBundleWithApim,
  '__SUBSCRIPTION_ID__',
  subscription().subscriptionId
)
var dashboardBundleWithResourceGroupName = replace(
  dashboardBundleWithSubscription,
  '__RESOURCE_GROUP_NAME__',
  resourceGroup().name
)
var dashboardBundleWithFinOpsResourceGroup = replace(
  dashboardBundleWithResourceGroupName,
  '__FINOPS_RESOURCE_GROUP_NAME__',
  finOpsResourceGroupName
)
var dashboardBundleWithFinOpsDataFactory = replace(
  dashboardBundleWithFinOpsResourceGroup,
  '__FINOPS_DATA_FACTORY_NAME__',
  finOpsDataFactoryName
)
var dashboardBundleWithLocation = replace(
  dashboardBundleWithFinOpsDataFactory,
  '__USAGE_LOCATION__',
  usageLocation
)
var dashboardBundleWithEventHubName = replace(
  dashboardBundleWithLocation,
  '__EVENT_HUB_NAMESPACE_NAME__',
  eventHubNamespaceName
)
var dashboardBundleWithEventHubId = replace(
  dashboardBundleWithEventHubName,
  '__EVENT_HUB_NAMESPACE_RESOURCE_ID__',
  eventHubNamespaceId
)
var dashboardBundleWithFunction = replace(
  dashboardBundleWithEventHubId,
  '__FUNCTION_APP_NAME__',
  functionAppName
)
var dashboardBundleText = replace(
  dashboardBundleWithFunction,
  '__STORAGE_BLOB_SERVICE_RESOURCE_ID__',
  storageBlobServiceId
)
var dashboardBundle = json(dashboardBundleText)

resource businessDashboard 'Microsoft.Dashboard/dashboards@2025-08-01' = {
  name: businessDashboardName
  location: location
  tags: union(tags, {
    GrafanaDashboardResourceType: 'microsoft.operationalinsights/workspaces'
    GrafanaDashboardTags: 'ai-observability,usage,cost-attribution,finops'
  })
  properties: {}
}

resource businessDashboardDefinition 'Microsoft.Dashboard/dashboards/dashboardDefinitions@2025-09-01-preview' = {
  parent: businessDashboard
  name: 'default'
  properties: {
    serializedData: string(dashboardBundle.business)
  }
}

resource operationsDashboard 'Microsoft.Dashboard/dashboards@2025-08-01' = {
  name: operationsDashboardName
  location: location
  tags: union(tags, {
    GrafanaDashboardResourceType: 'microsoft.operationalinsights/workspaces'
    GrafanaDashboardTags: 'ai-observability,pipeline,operations'
  })
  properties: {}
}

resource operationsDashboardDefinition 'Microsoft.Dashboard/dashboards/dashboardDefinitions@2025-09-01-preview' = {
  parent: operationsDashboard
  name: 'default'
  properties: {
    serializedData: string(dashboardBundle.operations)
  }
}

output dashboardId string = businessDashboard.id
output dashboardName string = businessDashboard.name
output businessDashboardId string = businessDashboard.id
output businessDashboardName string = businessDashboard.name
output operationsDashboardId string = operationsDashboard.id
output operationsDashboardName string = operationsDashboard.name
