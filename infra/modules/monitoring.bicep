targetScope = 'resourceGroup'

@description('Azure region for all monitoring resources.')
param location string

@description('Tags applied to every monitoring resource.')
param tags object

@description('Stable suffix used in demo resource names.')
param resourceSuffix string

var cleanSuffix = toLower(replace(resourceSuffix, '-', ''))
var lawName = 'ai-observability-demo-law-${cleanSuffix}'
var appInsightsName = 'ai-observability-demo-appi-${cleanSuffix}'
var foundryResourceId = resourceId(
  'Microsoft.CognitiveServices/accounts',
  'ai-observability-demo-foundry-${cleanSuffix}'
)
var apimResourceId = resourceId(
  'Microsoft.ApiManagement/service',
  'ai-observability-demo-apim-${resourceSuffix}'
)

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: appInsightsName
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
  }
}

var workbookWithWorkspace = replace(
  loadTextContent('../workbooks/monitoring-workbook.json'),
  '__WORKSPACE_RESOURCE_ID__',
  law.id
)
var workbookWithResourceGroup = replace(
  workbookWithWorkspace,
  '__RESOURCE_GROUP_ID__',
  resourceGroup().id
)
var workbookWithFoundry = replace(
  workbookWithResourceGroup,
  '__FOUNDRY_RESOURCE_ID__',
  foundryResourceId
)
var workbookJson = replace(workbookWithFoundry, '__APIM_RESOURCE_ID__', apimResourceId)

resource costGovernanceWorkbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, 'ai-observability-cost-governance-workbook')
  location: location
  kind: 'shared'
  tags: tags
  properties: {
    displayName: 'AI Usage and Cost Investigation'
    description: 'Filtered request, allocation, exception, and evidence ledgers for the AI usage attribution dashboards.'
    category: 'workbook'
    sourceId: law.id
    version: '1.0'
    serializedData: workbookJson
  }
}

output lawId string = law.id
output lawName string = law.name
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output appInsightsInstrumentationKey string = appInsights.properties.InstrumentationKey
output appInsightsName string = appInsights.name
output appInsightsId string = appInsights.id
output workbookId string = costGovernanceWorkbook.id
