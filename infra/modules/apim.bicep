targetScope = 'resourceGroup'

@description('Azure region for the API Management service.')
param location string

@description('Stable 6-character suffix used in demo resource names.')
param resourceSuffix string

@description('Foundry endpoint used as the backend service URL.')
param foundryEndpoint string

@description('Foundry account name, used to build the services.ai.azure.com data-plane URL for agent (Responses API) routing.')
param foundryAccountName string

@description('Application Insights instrumentation key used by the APIM logger.')
@secure()
param appInsightsInstrumentationKey string

@description('Log Analytics workspace resource ID for diagnostic settings.')
param logAnalyticsWorkspaceId string

@description('Name of the Event Hubs namespace used for pseudonymous usage events.')
param eventHubNamespaceName string

@description('Name of the event hub used for pseudonymous usage events.')
param usageEventHubName string

@description('Name of the Key Vault that stores the HMAC secret.')
param usageKeyVaultName string

@description('Versionless Key Vault reference for the usage HMAC key.')
param usageHmacKeyVaultReference string

@description('Tags applied to every resource in the demo platform.')
param tags object = {}

var apimName = 'ai-observability-demo-apim-${resourceSuffix}'
var gatewayUrl = 'https://${apimName}.azure-api.net'
var foundryAgentRoot = 'https://${foundryAccountName}.services.ai.azure.com'
var foundryProjectRoot = '${foundryAgentRoot}/api/projects/governed-model-comparison'
var openAiModelUrl = '${foundryEndpoint}openai'
var claudeModelUrl = '${foundryAgentRoot}/anthropic'
var eventHubsDataSenderRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '2b629674-e913-4c01-ae53-ef4638d8f975'
)
var keyVaultSecretsUserRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '4633458b-17de-408a-b874-0445c86b69e6'
)

resource apim 'Microsoft.ApiManagement/service@2023-09-01-preview' = {
  name: apimName
  location: location
  tags: tags
  sku: {
    name: 'BasicV2'
    capacity: 1
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: 'demo@example.invalid'
    publisherName: 'AI Observability Demo'
    developerPortalStatus: 'Disabled'
    legacyPortalStatus: 'Disabled'
    natGatewayState: 'Enabled'
    publicNetworkAccess: 'Enabled'
    customProperties: {
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Protocols.Server.Http2': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Ssl30': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls10': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Backend.Protocols.Tls11': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Ciphers.TripleDes168': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Ssl30': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls10': 'False'
      'Microsoft.WindowsAzure.ApiManagement.Gateway.Security.Protocols.Tls11': 'False'
    }
  }
}

resource tenantIdNamedValue 'Microsoft.ApiManagement/service/namedValues@2023-09-01-preview' = {
  parent: apim
  name: 'tenant-id'
  properties: {
    displayName: 'tenant-id'
    value: subscription().tenantId
    secret: false
  }
}

resource entraClientIdNamedValue 'Microsoft.ApiManagement/service/namedValues@2023-09-01-preview' = {
  parent: apim
  name: 'entra-client-id'
  properties: {
    displayName: 'entra-client-id'
    value: '00000000-0000-0000-0000-000000000000'
    secret: false
  }
}

resource appInsightsLogger 'Microsoft.ApiManagement/service/loggers@2023-09-01-preview' = {
  parent: apim
  name: 'applicationinsights'
  properties: {
    loggerType: 'applicationInsights'
    description: 'Application Insights logger for the AI Observability Demo gateway.'
    credentials: {
      instrumentationKey: appInsightsInstrumentationKey
    }
  }
}

resource eventHubNamespace 'Microsoft.EventHub/namespaces@2024-01-01' existing = {
  name: eventHubNamespaceName
}

resource usageEventHub 'Microsoft.EventHub/namespaces/eventhubs@2024-01-01' existing = {
  parent: eventHubNamespace
  name: usageEventHubName
}

resource usageKeyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: usageKeyVaultName
}

resource apimEventHubSender 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(usageEventHub.id, apim.id, eventHubsDataSenderRoleId)
  scope: usageEventHub
  properties: {
    roleDefinitionId: eventHubsDataSenderRoleId
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource apimKeyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(usageKeyVault.id, apim.id, keyVaultSecretsUserRoleId)
  scope: usageKeyVault
  properties: {
    roleDefinitionId: keyVaultSecretsUserRoleId
    principalId: apim.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource usageEventHubLogger 'Microsoft.ApiManagement/service/loggers@2024-05-01' = {
  parent: apim
  name: 'usage-event-hub'
  properties: {
    loggerType: 'azureEventHub'
    description: 'Managed-identity logger for pseudonymous AI usage records.'
    isBuffered: true
    resourceId: usageEventHub.id
    credentials: {
      endpointAddress: '${eventHubNamespace.name}.servicebus.windows.net'
      identityClientId: 'systemAssigned'
      name: usageEventHub.name
    }
  }
  dependsOn: [
    apimEventHubSender
  ]
}

resource usageHmacNamedValue 'Microsoft.ApiManagement/service/namedValues@2024-05-01' = {
  parent: apim
  name: 'usage-hmac-key'
  properties: {
    displayName: 'usage-hmac-key'
    secret: true
    keyVault: {
      secretIdentifier: usageHmacKeyVaultReference
    }
  }
  dependsOn: [
    apimKeyVaultSecretsUser
  ]
}

resource apimDiagnostic 'Microsoft.ApiManagement/service/diagnostics@2023-09-01-preview' = {
  parent: apim
  name: 'applicationinsights'
  properties: {
    loggerId: appInsightsLogger.id
    alwaysLog: 'allErrors'
    verbosity: 'information'
    logClientIp: false
    httpCorrelationProtocol: 'W3C'
    metrics: true
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: {
        headers: [
          'x-correlation-id'
          'Content-Type'
        ]
        body: {
          bytes: 0
        }
      }
      response: {
        headers: [
          'x-correlation-id'
          'Content-Type'
        ]
        body: {
          bytes: 0
        }
      }
    }
    backend: {
      request: {
        headers: [
          'x-correlation-id'
          'Content-Type'
        ]
        body: {
          bytes: 0
        }
      }
      response: {
        headers: [
          'x-correlation-id'
          'Content-Type'
        ]
        body: {
          bytes: 0
        }
      }
    }
  }
}

resource azureMonitorDiagnostic 'Microsoft.ApiManagement/service/diagnostics@2024-06-01-preview' = {
  parent: apim
  name: 'azuremonitor'
  properties: {
    loggerId: '${apim.id}/loggers/azuremonitor'
    logClientIp: false
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    // Capture model and token metadata without retaining prompts or completions.
    largeLanguageModel: {
      logs: 'enabled'
    }
    frontend: {
      request: {
        dataMasking: {
          queryParams: [
            {
              mode: 'Hide'
              value: '*'
            }
          ]
        }
      }
    }
    backend: {
      request: {
        dataMasking: {
          queryParams: [
            {
              mode: 'Hide'
              value: '*'
            }
          ]
        }
      }
    }
  }
}

resource apimLawDiagnostic 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-log-analytics'
  scope: apim
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        category: 'GatewayLogs'
        enabled: true
      }
      {
        category: 'GatewayLlmLogs'
        enabled: true
      }
      {
        category: 'GatewayMCPLogs'
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

resource openAiModelBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'foundry-openai-model'
  properties: {
    title: 'Foundry GPT-5.4 model'
    description: 'OpenAI Responses API endpoint for the GPT-5.4 deployment.'
    url: openAiModelUrl
    protocol: 'http'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

resource claudeModelBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'foundry-claude-model'
  properties: {
    title: 'Foundry Claude Opus 5 model'
    description: 'Anthropic Messages API endpoint for the Claude Opus 5 deployment.'
    url: claudeModelUrl
    protocol: 'http'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

resource weatherAgentBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'foundry-weather-agent'
  properties: {
    title: 'Foundry weather prompt agent'
    description: 'Foundry Agent Service Responses API endpoint for the optional weather demo.'
    url: foundryProjectRoot
    protocol: 'http'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
  }
}

resource contentSafetyBackend 'Microsoft.ApiManagement/service/backends@2024-05-01' = {
  parent: apim
  name: 'foundry-content-safety'
  properties: {
    title: 'Foundry Content Safety'
    description: 'Content Safety backend for gateway prompt and completion checks.'
    url: foundryEndpoint
    protocol: 'http'
    tls: {
      validateCertificateChain: true
      validateCertificateName: true
    }
    credentials: any({
      managedIdentity: {
        resource: 'https://cognitiveservices.azure.com'
      }
    })
  }
}

resource openAiModelApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'openai-model-api'
  properties: {
    displayName: 'OpenAI GPT-5.4'
    description: 'Governed OpenAI Responses API for the scientific engineering scenarios.'
    path: 'models/openai'
    protocols: [
      'https'
    ]
    serviceUrl: openAiModelUrl
    subscriptionRequired: true
    format: 'openapi+json'
    value: loadTextContent('../../apim-policies/openai-model-openapi.json')
  }
}

resource claudeModelApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'claude-model-api'
  properties: {
    displayName: 'Claude Opus 5'
    description: 'Governed Anthropic Messages API for model cost comparison.'
    path: 'models/claude'
    protocols: [
      'https'
    ]
    serviceUrl: claudeModelUrl
    subscriptionRequired: true
    format: 'openapi+json'
    value: loadTextContent('../../apim-policies/claude-model-openapi.json')
  }
}

resource protectedCodeApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'protected-code-api'
  properties: {
    displayName: 'Protected Material for Code'
    description: 'Direct Protected Material for Code detection through the governed gateway.'
    path: 'guardrails/protected-code'
    protocols: [
      'https'
    ]
    serviceUrl: foundryEndpoint
    subscriptionRequired: true
    format: 'openapi+json'
    value: loadTextContent('../../apim-policies/protected-code-openapi.json')
  }
}

resource weatherAgentApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'weather-agent-api'
  properties: {
    displayName: 'Weather Forecasting Agent'
    description: 'Governed Foundry prompt-agent invocation API.'
    path: 'agents/weather'
    protocols: [
      'https'
    ]
    serviceUrl: foundryProjectRoot
    subscriptionRequired: true
    format: 'openapi+json'
    value: loadTextContent('../../apim-policies/weather-agent-openapi.json')
  }
}

resource weatherAgentModelApi 'Microsoft.ApiManagement/service/apis@2024-05-01' = {
  parent: apim
  name: 'weather-agent-model-api'
  properties: {
    displayName: 'Weather Agent GPT-5.4 Model'
    description: 'OpenAI-compatible model API used by Foundry Agent Service through the gateway.'
    path: 'agent-model/v1'
    protocols: [
      'https'
    ]
    serviceUrl: openAiModelUrl
    subscriptionRequired: true
    format: 'openapi+json'
    value: loadTextContent('../../apim-policies/weather-agent-model-openapi.json')
  }
}

resource globalPolicy 'Microsoft.ApiManagement/service/policies@2023-09-01-preview' = {
  parent: apim
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../../apim-policies/global.xml')
  }
}

resource openAiModelApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: openAiModelApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../../apim-policies/openai-model.xml')
  }
  dependsOn: [
    openAiModelBackend
    contentSafetyBackend
    tenantIdNamedValue
    entraClientIdNamedValue
    usageEventHubLogger
    usageHmacNamedValue
  ]
}

resource claudeModelApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: claudeModelApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../../apim-policies/claude-model.xml')
  }
  dependsOn: [
    claudeModelBackend
    contentSafetyBackend
    tenantIdNamedValue
    entraClientIdNamedValue
    usageEventHubLogger
    usageHmacNamedValue
  ]
}

resource protectedCodeApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: protectedCodeApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../../apim-policies/protected-code.xml')
  }
  dependsOn: [
    contentSafetyBackend
    tenantIdNamedValue
    entraClientIdNamedValue
  ]
}

resource weatherAgentApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: weatherAgentApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../../apim-policies/weather-agent.xml')
  }
  dependsOn: [
    weatherAgentBackend
    contentSafetyBackend
    tenantIdNamedValue
    entraClientIdNamedValue
  ]
}

resource weatherAgentModelApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2024-05-01' = {
  parent: weatherAgentModelApi
  name: 'policy'
  properties: {
    format: 'rawxml'
    value: loadTextContent('../../apim-policies/weather-agent-model.xml')
  }
  dependsOn: [
    openAiModelBackend
    contentSafetyBackend
    usageEventHubLogger
    usageHmacNamedValue
  ]
}

resource presenterProduct 'Microsoft.ApiManagement/service/products@2024-05-01' = {
  parent: apim
  name: 'presenter'
  properties: {
    displayName: 'Presenter'
    description: 'Live signed-in demonstration traffic.'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

resource researchProduct 'Microsoft.ApiManagement/service/products@2024-05-01' = {
  parent: apim
  name: 'research'
  properties: {
    displayName: 'Research'
    description: 'Synthetic research team traffic.'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

resource engineeringProduct 'Microsoft.ApiManagement/service/products@2024-05-01' = {
  parent: apim
  name: 'engineering'
  properties: {
    displayName: 'Engineering'
    description: 'Synthetic engineering team traffic.'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

resource agentProduct 'Microsoft.ApiManagement/service/products@2024-05-01' = {
  parent: apim
  name: 'agents'
  properties: {
    displayName: 'Agents'
    description: 'Governed Foundry agent model and MCP traffic.'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

resource presenterAnalyticsUser 'Microsoft.ApiManagement/service/users@2024-05-01' = {
  parent: apim
  name: 'presenter-analytics-user'
  properties: {
    email: 'presenter@example.invalid'
    firstName: 'Presenter'
    lastName: 'Demo'
    state: 'active'
    note: 'Synthetic owner used for APIM Analytics dimensions.'
  }
}

resource researchAnalyticsUser 'Microsoft.ApiManagement/service/users@2024-05-01' = {
  parent: apim
  name: 'research-analytics-user'
  properties: {
    email: 'research@example.invalid'
    firstName: 'Research'
    lastName: 'Team'
    state: 'active'
    note: 'Synthetic owner used for APIM Analytics dimensions.'
  }
}

resource engineeringAnalyticsUser 'Microsoft.ApiManagement/service/users@2024-05-01' = {
  parent: apim
  name: 'engineering-analytics-user'
  properties: {
    email: 'engineering@example.invalid'
    firstName: 'Engineering'
    lastName: 'Team'
    state: 'active'
    note: 'Synthetic owner used for APIM Analytics dimensions.'
  }
}

resource weatherAgentUser 'Microsoft.ApiManagement/service/users@2024-05-01' = {
  parent: apim
  name: 'weather-agent-user'
  properties: {
    email: 'weather-agent@example.invalid'
    firstName: 'Weather'
    lastName: 'Agent'
    state: 'active'
    note: 'Demo owner used for APIM Analytics dimensions.'
  }
}

resource presenterOpenAiApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: presenterProduct
  name: openAiModelApi.name
}

resource presenterClaudeApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: presenterProduct
  name: claudeModelApi.name
}

resource presenterProtectedCodeApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: presenterProduct
  name: protectedCodeApi.name
}

resource presenterWeatherAgentApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: presenterProduct
  name: weatherAgentApi.name
}

resource agentWeatherModelApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: agentProduct
  name: weatherAgentModelApi.name
}

resource researchProtectedCodeApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: researchProduct
  name: protectedCodeApi.name
}

resource engineeringProtectedCodeApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: engineeringProduct
  name: protectedCodeApi.name
}

resource researchOpenAiApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: researchProduct
  name: openAiModelApi.name
}

resource researchClaudeApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: researchProduct
  name: claudeModelApi.name
}

resource engineeringOpenAiApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: engineeringProduct
  name: openAiModelApi.name
}

resource engineeringClaudeApi 'Microsoft.ApiManagement/service/products/apis@2024-05-01' = {
  parent: engineeringProduct
  name: claudeModelApi.name
}

resource presenterSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = {
  parent: apim
  name: 'presenter-sub'
  properties: {
    displayName: 'presenter-sub'
    scope: presenterProduct.id
    ownerId: replace(presenterAnalyticsUser.id, apim.id, '')
    state: 'active'
    allowTracing: false
  }
}

resource researchSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = {
  parent: apim
  name: 'research-team-sub'
  properties: {
    displayName: 'research-team-sub'
    scope: researchProduct.id
    ownerId: replace(researchAnalyticsUser.id, apim.id, '')
    state: 'active'
    allowTracing: false
  }
}

resource engineeringSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = {
  parent: apim
  name: 'engineering-team-sub'
  properties: {
    displayName: 'engineering-team-sub'
    scope: engineeringProduct.id
    ownerId: replace(engineeringAnalyticsUser.id, apim.id, '')
    state: 'active'
    allowTracing: false
  }
}

resource weatherAgentSubscription 'Microsoft.ApiManagement/service/subscriptions@2024-05-01' = {
  parent: apim
  name: 'weather-agent-sub'
  properties: {
    displayName: 'weather-agent-sub'
    scope: agentProduct.id
    ownerId: replace(weatherAgentUser.id, apim.id, '')
    state: 'active'
    allowTracing: false
  }
}

resource foundry 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: foundryAccountName
}

resource modelComparisonProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: foundry
  name: 'governed-model-comparison'
}

resource weatherAgentModelConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-09-01' = {
  parent: modelComparisonProject
  name: 'weather-agent-model'
  properties: {
    category: 'ApiManagement'
    target: '${gatewayUrl}/${weatherAgentModelApi.properties.path}'
    authType: 'ApiKey'
    isSharedToAll: false
    credentials: {
      key: weatherAgentSubscription.listSecrets().primaryKey
    }
    metadata: {
      deploymentInPath: 'false'
      inferenceAPIVersion: '2025-04-01-preview'
      authConfig: string({
        type: 'api_key'
        name: 'Ocp-Apim-Subscription-Key'
        format: '{api_key}'
      })
      models: string([
        {
          name: 'gpt-5.4'
          properties: {
            model: {
              name: 'gpt-5.4'
              version: '2026-03-05'
              format: 'OpenAI'
            }
          }
        }
      ])
    }
  }
}

output apimName string = apim.name
output gatewayUrl string = gatewayUrl
output apimPrincipalId string = apim.identity.principalId
output usageEventHubLoggerId string = usageEventHubLogger.id
output usageEventHubLoggerName string = usageEventHubLogger.name
output usageHmacNamedValueId string = usageHmacNamedValue.id
output openAiModelApiUrl string = '${gatewayUrl}/${openAiModelApi.properties.path}/responses?api-version=2025-04-01-preview'
output claudeModelApiUrl string = '${gatewayUrl}/${claudeModelApi.properties.path}/v1/messages'
output protectedCodeApiUrl string = '${gatewayUrl}/${protectedCodeApi.properties.path}/check'
output weatherAgentApiUrl string = '${gatewayUrl}/${weatherAgentApi.properties.path}/responses'
output weatherAgentModelName string = '${weatherAgentModelConnection.name}/gpt-5.4'
output weatherAgentSubscriptionId string = weatherAgentSubscription.name

@secure()
output presenterSubscriptionKey string = presenterSubscription.listSecrets().primaryKey

@secure()
output researchSubscriptionKey string = researchSubscription.listSecrets().primaryKey

@secure()
output engineeringSubscriptionKey string = engineeringSubscription.listSecrets().primaryKey
