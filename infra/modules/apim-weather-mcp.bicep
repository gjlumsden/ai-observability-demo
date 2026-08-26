targetScope = 'resourceGroup'

@description('Name of the existing API Management service.')
param apimName string

@description('Base URL of the web application that hosts the weather REST operation.')
param webAppUrl string

var mcpServerId = 'weather-tools'
var backendKeyNamedValueId = 'weather-mcp-backend-key'
var gatewayUrl = 'https://${apimName}.azure-api.net'

resource apim 'Microsoft.ApiManagement/service@2025-09-01-preview' existing = {
  name: apimName
}

resource backendKey 'Microsoft.ApiManagement/service/namedValues@2025-09-01-preview' = {
  parent: apim
  name: backendKeyNamedValueId
  properties: {
    displayName: backendKeyNamedValueId
    value: 'replace-after-provision'
    secret: true
  }
}

resource weatherRestApi 'Microsoft.ApiManagement/service/apis@2025-09-01-preview' = {
  parent: apim
  name: 'weather-rest-api'
  properties: {
    displayName: 'Weather forecast backend'
    description: 'REST operation used by the APIM-native weather MCP server.'
    path: 'weather-backend'
    protocols: [
      'https'
    ]
    serviceUrl: '${webAppUrl}/api/weather'
    subscriptionRequired: true
    format: 'openapi+json'
    value: loadTextContent('../../apim-policies/weather-api-openapi.json')
  }
}

resource weatherRestPolicy 'Microsoft.ApiManagement/service/apis/policies@2025-09-01-preview' = {
  parent: weatherRestApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../../apim-policies/weather-api.xml')
  }
  dependsOn: [
    backendKey
  ]
}

resource weatherMcpServer 'Microsoft.ApiManagement/service/apis@2025-09-01-preview' = {
  parent: apim
  name: mcpServerId
  properties: {
    type: 'mcp'
    displayName: 'Weather forecast tools'
    description: 'APIM-native MCP server backed by the weather REST operation.'
    path: mcpServerId
    protocols: [
      'https'
    ]
    subscriptionRequired: true
  }
}

resource weatherMcpPolicy 'Microsoft.ApiManagement/service/apis/policies@2025-09-01-preview' = {
  parent: weatherMcpServer
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../../apim-policies/weather-mcp.xml')
  }
}

resource weatherForecastTool 'Microsoft.ApiManagement/service/apis/tools@2025-09-01-preview' = {
  parent: weatherMcpServer
  name: 'get_weather_forecast'
  properties: {
    displayName: 'get_weather_forecast'
    description: 'Get a one-to-seven-day public weather forecast for a named global location.'
    operationId: resourceId(
      'Microsoft.ApiManagement/service/apis/operations',
      apimName,
      weatherRestApi.name,
      'getWeatherForecast'
    )
  }
  dependsOn: [
    weatherRestApi
  ]
}

resource agentProduct 'Microsoft.ApiManagement/service/products@2025-09-01-preview' existing = {
  parent: apim
  name: 'agents'
}

resource productBinding 'Microsoft.ApiManagement/service/products/apis@2025-09-01-preview' = {
  parent: agentProduct
  name: weatherMcpServer.name
}

resource weatherRestProductBinding 'Microsoft.ApiManagement/service/products/apis@2025-09-01-preview' = {
  parent: agentProduct
  name: weatherRestApi.name
}

output mcpServerUrl string = '${gatewayUrl}/${weatherMcpServer.properties.path}/mcp'
output backendKeyNamedValueId string = backendKey.name
