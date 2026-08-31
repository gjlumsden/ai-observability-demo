targetScope = 'resourceGroup'

@description('Azure region for Key Vault resources.')
param location string

@description('Tags applied to Key Vault resources.')
param tags object

@description('Stable suffix used in resource names.')
param resourceSuffix string

@description('A non-sensitive value that reruns the idempotent HMAC key bootstrap.')
param hmacBootstrapRunId string

var cleanSuffix = toLower(replace(resourceSuffix, '-', ''))
var keyVaultName = take('aiobs-kv-${cleanSuffix}', 24)
var secretName = 'usage-hmac-key'
var keyVaultSecretsOfficerRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
)

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enablePurgeProtection: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
  }
}

resource secretBootstrapIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'aiobs-hmac-bootstrap-${cleanSuffix}'
  location: location
  tags: tags
}

resource secretBootstrapRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, secretBootstrapIdentity.id, keyVaultSecretsOfficerRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: keyVaultSecretsOfficerRoleId
    principalId: secretBootstrapIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

resource secretBootstrap 'Microsoft.Resources/deploymentScripts@2023-08-01' = {
  name: 'create-usage-hmac-${cleanSuffix}'
  location: location
  kind: 'AzureCLI'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${secretBootstrapIdentity.id}': {}
    }
  }
  properties: {
    azCliVersion: '2.64.0'
    cleanupPreference: 'Always'
    forceUpdateTag: hmacBootstrapRunId
    retentionInterval: 'P1D'
    timeout: 'PT15M'
    environmentVariables: [
      {
        name: 'KEY_VAULT_URI'
        value: keyVault.properties.vaultUri
      }
      {
        name: 'SECRET_NAME'
        value: secretName
      }
      {
        name: 'IDENTITY_CLIENT_ID'
        value: secretBootstrapIdentity.properties.clientId
      }
    ]
    scriptContent: '''
      set -euo pipefail

      for attempt in $(seq 1 60); do
        token="$(curl --fail --silent --show-error -H Metadata:true "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=https%3A%2F%2Fvault.azure.net&client_id=${IDENTITY_CLIENT_ID}" | jq -r .access_token)"
        if curl --fail --silent --show-error \
          -H "Authorization: Bearer $token" \
          "${KEY_VAULT_URI}secrets/${SECRET_NAME}?api-version=7.4" \
          >/dev/null 2>/dev/null; then
          unset token
          exit 0
        fi

        secret_value="$(openssl rand -base64 48 | tr -d '\n')"
        body="$(jq -cn --arg value "$secret_value" '{value:$value, attributes:{enabled:true}}')"
        if curl --fail --silent --show-error \
          -X PUT \
          -H "Authorization: Bearer $token" \
          -H 'Content-Type: application/json' \
          --data "$body" \
          "${KEY_VAULT_URI}secrets/${SECRET_NAME}?api-version=7.4" \
          >/dev/null 2>/dev/null; then
          unset secret_value
          unset token
          unset body
          exit 0
        fi

        unset secret_value
        unset token
        unset body
        sleep 10
      done

      echo "Could not create or read the HMAC secret." >&2
      exit 1
    '''
  }
  dependsOn: [
    secretBootstrapRole
  ]
}

output keyVaultName string = keyVault.name
output keyVaultId string = keyVault.id
output secretName string = secretName
output secretIdentifier string = '${keyVault.properties.vaultUri}secrets/${secretName}'
output bootstrapRoleAssignmentId string = secretBootstrapRole.id
