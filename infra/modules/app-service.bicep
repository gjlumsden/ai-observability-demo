targetScope = 'resourceGroup'

@description('Azure region for the App Service resources.')
param location string = resourceGroup().location

@description('Stable 6-character suffix used in demo resource names.')
param resourceSuffix string

@description('Tags applied to App Service resources.')
param tags object = {}

@description('Log Analytics workspace resource ID for diagnostic settings.')
param logAnalyticsWorkspaceId string

@description('Base URL for the API Management gateway.')
param apimBaseUrl string

@secure()
@description('APIM subscription key for the signed-in model comparison product.')
param apimPresenterKey string

@description('Microsoft Entra tenant ID used by the web app.')
param entraTenantId string

@description('Microsoft Entra client ID used by the web app. This is a placeholder updated post-provision.')
param entraClientId string

@description('Application Insights connection string.')
param applicationInsightsConnectionString string

var serviceTags = union(tags, {
  'azd-service-name': 'web'
})
var webAppName = 'ai-observability-demo-web-${resourceSuffix}'

resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'ai-observability-demo-plan-${resourceSuffix}'
  location: location
  tags: serviceTags
  kind: 'linux'
  sku: {
    name: 'B1'
    tier: 'Basic'
    size: 'B1'
    family: 'B'
    capacity: 1
  }
  properties: {
    reserved: true
  }
}

resource webApp 'Microsoft.Web/sites@2024-04-01' = {
  name: webAppName
  location: location
  tags: serviceTags
  kind: 'app,linux'
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    clientAffinityEnabled: false
    siteConfig: {
      linuxFxVersion: 'NODE|24-lts'
      alwaysOn: true
      ftpsState: 'FtpsOnly'
      minTlsVersion: '1.2'
      appSettings: [
        {
          name: 'WEBSITE_NODE_DEFAULT_VERSION'
          value: '~24'
        }
        {
          name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'
          value: 'true'
        }
        {
          name: 'APIM_BASE_URL'
          value: apimBaseUrl
        }
        {
          name: 'APIM_PRESENTER_KEY'
          value: apimPresenterKey
        }
        {
          name: 'ENTRA_TENANT_ID'
          value: entraTenantId
        }
        {
          name: 'ENTRA_CLIENT_ID'
          value: entraClientId
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: applicationInsightsConnectionString
        }
        {
          name: 'OTEL_SERVICE_NAME'
          value: webAppName
        }
        {
          name: 'OTEL_TRACES_SAMPLER'
          value: 'always_on'
        }
        {
          name: 'NODE_ENV'
          value: 'production'
        }
        {
          name: 'WEBSITES_PORT'
          value: '3000'
        }
      ]
    }
  }
}

resource webAppDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'ai-observability-demo-web-diagnostics'
  scope: webApp
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'AppServiceHTTPLogs'
        enabled: true
      }
      {
        category: 'AppServiceConsoleLogs'
        enabled: true
      }
      {
        category: 'AppServiceAppLogs'
        enabled: true
      }
      {
        category: 'AppServicePlatformLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output webAppName string = webApp.name
output webAppUrl string = 'https://${webApp.properties.defaultHostName}'
