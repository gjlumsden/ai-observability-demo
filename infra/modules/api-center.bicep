targetScope = 'resourceGroup'

@description('Azure region for API Center.')
param location string

@description('Stable 6-character suffix used in demo resource names.')
param resourceSuffix string

@description('Tags applied to every resource in the demo platform.')
param tags object = {}

var apiCenterName = 'ai-observability-demo-apic-${resourceSuffix}'

resource apiCenter 'Microsoft.ApiCenter/services@2024-03-01' = {
  name: apiCenterName
  location: location
  tags: tags
  sku: {
    name: 'Free'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {}
}

resource defaultWorkspace 'Microsoft.ApiCenter/services/workspaces@2024-03-01' = {
  parent: apiCenter
  name: 'default'
  properties: {
    title: 'Default workspace'
    description: 'Default API Center workspace for the AI Observability Demo.'
  }
}

resource openAiModelApi 'Microsoft.ApiCenter/services/workspaces/apis@2024-03-01' = {
  parent: defaultWorkspace
  name: 'openai-model-api'
  properties: {
    title: 'Governed OpenAI model API'
    description: 'APIM facade for the GPT model used by both scientific engineering scenarios.'
    kind: 'REST'
    customProperties: {
      apiType: 'rest'
    }
  }
}

resource claudeModelApi 'Microsoft.ApiCenter/services/workspaces/apis@2024-03-01' = {
  parent: defaultWorkspace
  name: 'claude-model-api'
  properties: {
    title: 'Governed Claude model API'
    description: 'APIM facade for the Claude model used by Governed Model Comparison.'
    kind: 'REST'
    customProperties: {
      apiType: 'rest'
    }
  }
}

resource protectedCodeApi 'Microsoft.ApiCenter/services/workspaces/apis@2024-03-01' = {
  parent: defaultWorkspace
  name: 'protected-code-api'
  properties: {
    title: 'Protected Material for Code API'
    description: 'Governed direct detection API used by the Scientific Code Explainer.'
    kind: 'REST'
    customProperties: {
      apiType: 'rest'
    }
  }
}

output apiCenterName string = apiCenter.name
output apiCenterPortalUrl string = 'https://portal.azure.com/#view/Microsoft_Azure_ApiCenter/ServiceMenuBlade/~/overview/resourceId/${apiCenter.id}'
