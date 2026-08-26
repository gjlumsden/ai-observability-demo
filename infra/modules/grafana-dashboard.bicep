targetScope = 'resourceGroup'

@description('Azure region for the Azure Monitor Grafana dashboard.')
param location string

@description('Tags applied to the Grafana dashboard.')
param tags object

@description('Resource ID of the Log Analytics workspace queried by the dashboard.')
param logAnalyticsWorkspaceId string

var dashboardName = 'AI-Observability-and-Cost'
var dashboardJson = replace(
  loadTextContent('../dashboards/grafana-dashboard.json'),
  '__WORKSPACE_RESOURCE_ID__',
  logAnalyticsWorkspaceId
)

resource dashboard 'Microsoft.Dashboard/dashboards@2025-08-01' = {
  name: dashboardName
  location: location
  tags: union(tags, {
    GrafanaDashboardResourceType: 'microsoft.insights/components'
    GrafanaDashboardTags: 'ai-observability,finops'
  })
  properties: {}
}

resource dashboardDefinition 'Microsoft.Dashboard/dashboards/dashboardDefinitions@2025-09-01-preview' = {
  parent: dashboard
  name: 'default'
  properties: {
    serializedData: dashboardJson
  }
}

output dashboardId string = dashboard.id
output dashboardName string = dashboard.name
