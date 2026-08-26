targetScope = 'resourceGroup'

@description('Azure Policy assignment location for assignment metadata.')
param location string = resourceGroup().location

@description('Azure locations permitted by the allowed locations audit policy.')
param allowedLocations string[]

var allowedLocationsPolicyDefinitionId = tenantResourceId('Microsoft.Authorization/policyDefinitions', 'e56962a6-4747-49cd-b67b-bf8b01975c4c')
var requireTagPolicyDefinitionId = tenantResourceId('Microsoft.Authorization/policyDefinitions', '871b6d14-10aa-478d-b590-94f262ecfa99')
var diagnosticSettingsPolicyDefinitionId = tenantResourceId('Microsoft.Authorization/policyDefinitions', '7f89b1eb-583c-429a-8828-af049802c1d9')
var secureTransferPolicyDefinitionId = tenantResourceId('Microsoft.Authorization/policyDefinitions', '404c3081-a854-4457-ae30-26a93ef643f9')

resource allowedLocationsAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'ai-observability-demo-allowed-locations-audit'
  location: location
  properties: {
    displayName: 'AI Observability Demo - Allowed locations (Audit)'
    description: 'Audit resources that use a location outside the deployment locations.'
    policyDefinitionId: allowedLocationsPolicyDefinitionId
    enforcementMode: 'Default'
    parameters: {
      listOfAllowedLocations: {
        value: allowedLocations
      }
      effect: {
        value: 'Audit'
      }
    }
  }
}

resource requireEnvTagAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'ai-observability-demo-require-env-tag-audit'
  location: location
  properties: {
    displayName: 'AI Observability Demo - Require env tag (Audit)'
    description: 'Audit-only assignment for resources missing the env tag.'
    policyDefinitionId: requireTagPolicyDefinitionId
    enforcementMode: 'DoNotEnforce'
    parameters: {
      tagName: {
        value: 'env'
      }
    }
  }
}

resource requireOwnerTagAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'ai-observability-demo-require-owner-tag-audit'
  location: location
  properties: {
    displayName: 'AI Observability Demo - Require owner tag (Audit)'
    description: 'Audit-only assignment for resources missing the owner tag.'
    policyDefinitionId: requireTagPolicyDefinitionId
    enforcementMode: 'DoNotEnforce'
    parameters: {
      tagName: {
        value: 'owner'
      }
    }
  }
}

resource appServiceDiagnosticsAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'ai-observability-demo-appsvc-diag-audit'
  location: location
  properties: {
    displayName: 'AI Observability Demo - App Service diagnostic settings (Audit)'
    description: 'Audit App Service resources without diagnostic settings.'
    policyDefinitionId: diagnosticSettingsPolicyDefinitionId
    enforcementMode: 'Default'
    parameters: {
      listOfResourceTypes: {
        value: [
          'Microsoft.Web/sites'
        ]
      }
      logsEnabled: {
        value: true
      }
      metricsEnabled: {
        value: true
      }
    }
  }
}

resource secureTransferAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: 'ai-observability-demo-storage-secure-transfer-audit'
  location: location
  properties: {
    displayName: 'AI Observability Demo - Storage secure transfer (Audit)'
    description: 'Audit storage accounts that do not require secure transfer.'
    policyDefinitionId: secureTransferPolicyDefinitionId
    enforcementMode: 'Default'
    parameters: {
      effect: {
        value: 'Audit'
      }
    }
  }
}

output assignmentIds array = [
  allowedLocationsAssignment.id
  requireEnvTagAssignment.id
  requireOwnerTagAssignment.id
  appServiceDiagnosticsAssignment.id
  secureTransferAssignment.id
]
