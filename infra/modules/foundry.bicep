targetScope = 'resourceGroup'

@description('Azure region for Microsoft Foundry.')
param location string

@description('Tags applied to Microsoft Foundry resources.')
param tags object

@description('Stable suffix used in demo resource names.')
param resourceSuffix string

@description('Log Analytics workspace resource ID for diagnostic settings.')
param logAnalyticsWorkspaceId string

@description('Application Insights resource ID to attach as a project connection for agent tracing.')
param appInsightsId string

@description('Application Insights connection string used as the connection credential.')
@secure()
param appInsightsConnectionString string

@description('GPT-5.4 model version from the Azure AI Foundry catalog.')
param gpt54ModelVersion string = '2026-03-05'

@description('GPT-5.4 mini model version from the Azure AI Foundry catalog.')
param gpt54MiniModelVersion string = '2026-03-17'

@description('GPT-5.4 nano model version from the Azure AI Foundry catalog.')
param gpt54NanoModelVersion string = '2026-03-17'

@description('Claude Opus model name from the Microsoft Foundry catalog.')
param claudeOpusModel string = 'claude-opus-5'

@description('Claude Opus hosting version. Version 2 is hosted on Azure.')
param claudeOpusModelVersion string = '2'

@minValue(1)
@description('Claude Opus Global Standard deployment capacity.')
param claudeOpusCapacity int = 10

@description('Organization name supplied to the Anthropic Marketplace offer.')
param claudeOrganizationName string = 'AI Observability Demo'

@description('ISO country code supplied to the Anthropic Marketplace offer.')
param claudeCountryCode string = 'GB'

@description('Industry supplied to the Anthropic Marketplace offer.')
param claudeIndustry string = 'government'

var cleanSuffix = toLower(replace(resourceSuffix, '-', ''))
var foundryName = 'ai-observability-demo-foundry-${cleanSuffix}'
var monitoringMetricsPublisherRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '3913510d-42f4-4e42-8a64-420c390055eb'
)

resource foundry 'Microsoft.CognitiveServices/accounts@2025-10-01-preview' = {
  name: foundryName
  location: location
  tags: tags
  kind: 'AIServices'
  identity: {
    type: 'SystemAssigned'
  }
  sku: {
    name: 'S0'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: foundryName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

resource modelComparisonProject 'Microsoft.CognitiveServices/accounts/projects@2025-10-01-preview' = {
  parent: foundry
  name: 'governed-model-comparison'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
  dependsOn: [
    claudeOpusDeployment
  ]
}

resource scientificCodeProject 'Microsoft.CognitiveServices/accounts/projects@2025-10-01-preview' = {
  parent: foundry
  name: 'scientific-code-explainer'
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
  dependsOn: [
    modelComparisonProject
  ]
}

// RAI (Responsible AI) content-filter policy applied to all model deployments.
// Medium severity threshold with blocking on hate/sexual/violence/self-harm,
// Prompt Shields and protected code blocking are enabled for code generation.
resource raiPolicyAiObservabilityDemo 'Microsoft.CognitiveServices/accounts/raiPolicies@2024-10-01' = {
  parent: foundry
  name: 'rai-ai-observability-demo'
  properties: {
    basePolicyName: 'Microsoft.DefaultV2'
    mode: 'Blocking'
    contentFilters: [
      // Prompt content filters (severity-based)
      { name: 'Hate', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Prompt' }
      { name: 'Sexual', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Prompt' }
      { name: 'Violence', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Prompt' }
      { name: 'Selfharm', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Prompt' }
      // Completion content filters (severity-based)
      { name: 'Hate', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Completion' }
      { name: 'Sexual', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Completion' }
      { name: 'Violence', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Completion' }
      { name: 'Selfharm', blocking: true, enabled: true, severityThreshold: 'Medium', source: 'Completion' }
      // Prompt Shields — direct jailbreak attacks on user prompts
      { name: 'Jailbreak', blocking: true, enabled: true, source: 'Prompt' }
      // Prompt Shields — indirect attacks (injection via retrieved/tool content)
      { name: 'Indirect Attack', blocking: true, enabled: true, source: 'Prompt' }
      // Protected material text detection on completions (annotate-only)
      { name: 'Protected Material Text', blocking: false, enabled: true, source: 'Completion' }
      // Protected material code detection on completions (filter mode)
      { name: 'Protected Material Code', blocking: true, enabled: true, source: 'Completion' }
    ]
  }
}

resource gpt54Deployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: foundry
  name: 'gpt-5.4'
  sku: {
    name: 'GlobalStandard'
    capacity: 50
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-5.4'
      version: gpt54ModelVersion
    }
    raiPolicyName: raiPolicyAiObservabilityDemo.name
  }
}

resource gpt54MiniDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: foundry
  name: 'gpt-5.4-mini'
  sku: {
    name: 'GlobalStandard'
    capacity: 200
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-5.4-mini'
      version: gpt54MiniModelVersion
    }
    raiPolicyName: raiPolicyAiObservabilityDemo.name
  }
  dependsOn: [
    gpt54Deployment
  ]
}

resource gpt54NanoDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = {
  parent: foundry
  name: 'gpt-5.4-nano'
  sku: {
    name: 'GlobalStandard'
    capacity: 500
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: 'gpt-5.4-nano'
      version: gpt54NanoModelVersion
    }
    raiPolicyName: raiPolicyAiObservabilityDemo.name
  }
  dependsOn: [
    gpt54MiniDeployment
  ]
}

// This follows the Microsoft-maintained Azure-Samples/claude deployment shape.
resource claudeOpusDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview' = {
  parent: foundry
  name: claudeOpusModel
  sku: {
    name: 'GlobalStandard'
    capacity: claudeOpusCapacity
  }
  properties: {
    model: {
      format: 'Anthropic'
      name: claudeOpusModel
      version: claudeOpusModelVersion
    }
    modelProviderData: {
      organizationName: claudeOrganizationName
      countryCode: claudeCountryCode
      industry: claudeIndustry
    }
    versionUpgradeOption: 'OnceNewDefaultVersionAvailable'
    raiPolicyName: 'Microsoft.DefaultV2'
  }
  dependsOn: [
    gpt54NanoDeployment
  ]
}

resource foundryDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${foundry.name}'
  scope: foundry
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        category: 'Audit'
        enabled: true
      }
      {
        category: 'RequestResponse'
        enabled: true
      }
      {
        category: 'Trace'
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
  dependsOn: [
    gpt54Deployment
    gpt54MiniDeployment
    gpt54NanoDeployment
    claudeOpusDeployment
  ]
}

output foundryName string = foundry.name
output foundryEndpoint string = foundry.properties.endpoint
output foundryId string = foundry.id
output modelComparisonProjectId string = modelComparisonProject.id
output scientificCodeProjectId string = scientificCodeProject.id
output foundryPrincipalId string = foundry.identity.principalId
output raiPolicyName string = raiPolicyAiObservabilityDemo.name
output claudeBaseUrl string = 'https://${foundry.name}.services.ai.azure.com/anthropic'
output claudeMessagesEndpoint string = 'https://${foundry.name}.services.ai.azure.com/anthropic/v1/messages'
output claudeOpusDeploymentName string = claudeOpusDeployment.name

// App Insights connection on each project — enables Foundry server-side
// OpenTelemetry GenAI tracing for the Agents (Preview) view in App Insights.
resource appInsights 'Microsoft.Insights/components@2020-02-02' existing = {
  name: last(split(appInsightsId, '/'))
}

resource modelComparisonTracePublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appInsights.id, modelComparisonProject.id, monitoringMetricsPublisherRoleDefinitionId)
  scope: appInsights
  properties: {
    principalId: modelComparisonProject.identity.principalId
    roleDefinitionId: monitoringMetricsPublisherRoleDefinitionId
    principalType: 'ServicePrincipal'
  }
}

resource scientificCodeTracePublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(appInsights.id, scientificCodeProject.id, monitoringMetricsPublisherRoleDefinitionId)
  scope: appInsights
  properties: {
    principalId: scientificCodeProject.identity.principalId
    roleDefinitionId: monitoringMetricsPublisherRoleDefinitionId
    principalType: 'ServicePrincipal'
  }
}

resource modelComparisonAppInsightsConn 'Microsoft.CognitiveServices/accounts/projects/connections@2025-09-01' = {
  parent: modelComparisonProject
  name: 'core-app-insights-model-comparison'
  properties: {
    category: 'AppInsights'
    target: appInsightsId
    authType: 'ProjectManagedIdentity'
    isSharedToAll: false
    metadata: {
      ApiType: 'Azure'
      ResourceId: appInsightsId
      ApplicationInsightsConnectionString: appInsightsConnectionString
    }
  }
  dependsOn: [
    modelComparisonTracePublisher
  ]
}

resource scientificCodeAppInsightsConn 'Microsoft.CognitiveServices/accounts/projects/connections@2025-09-01' = {
  parent: scientificCodeProject
  name: 'core-app-insights-code-explainer'
  properties: {
    category: 'AppInsights'
    target: appInsightsId
    authType: 'ProjectManagedIdentity'
    isSharedToAll: false
    metadata: {
      ApiType: 'Azure'
      ResourceId: appInsightsId
      ApplicationInsightsConnectionString: appInsightsConnectionString
    }
  }
  dependsOn: [
    scientificCodeTracePublisher
  ]
}
