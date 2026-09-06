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
        {
          // Required for MISE-backed platform authentication. See authsettingsV2 below;
          // this flag turns on the MISE token-validation engine inside App Service's auth layer.
          name: 'WEBSITE_AAD_ENABLE_MISE'
          value: 'true'
        }
      ]
    }
  }
}

@description('Azure App Service Authentication ("Easy Auth"), the platform-enforced, MISE-backed replacement for in-app MSAL/session sign-in.')
resource webAppAuthSettings 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: webApp
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
    }
    globalValidation: {
      // Deliberately NOT "requireAuthentication: true" for the whole app: this app has a public
      // home page, a public /healthz probe, and a machine-to-machine /api/weather/forecast route
      // protected by its own x-mcp-key check. Microsoft's own guidance for that shape is
      // "Allow unauthenticated requests" so app code makes the per-route decision (see
      // src/web/middleware/auth.js requireAuth), while Easy Auth still fully validates signature,
      // issuer, audience, and lifetime for any request that IS authenticated, forwarding the
      // verified identity via X-MS-CLIENT-PRINCIPAL-*/X-MS-TOKEN-AAD-* headers.
      // Reference: https://learn.microsoft.com/azure/app-service/overview-authentication-authorization#how-it-works
      requireAuthentication: false
      unauthenticatedClientAction: 'AllowAnonymous'
    }
    identityProviders: {
      azureActiveDirectory: {
        // Disabled until postprovision creates the Entra app registration and populates the real
        // client ID/secret; a placeholder client ID cannot be enabled safely. The lifecycle/hooks
        // owner finalizes this with `az webapp auth update` once entraClientId is known.
        enabled: !empty(entraClientId)
        registration: {
          clientId: entraClientId
          clientSecretSettingName: 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'
          openIdIssuer: '${environment().authentication.loginEndpoint}${entraTenantId}/v2.0'
        }
        login: {
          // Requests the same delegated "access_as_user" scope the app previously acquired via
          // MSAL, so the resulting AAD access token keeps working as the APIM Bearer token.
          loginParameters: [
            'scope=openid profile email offline_access api://${entraClientId}/access_as_user'
          ]
        }
        validation: {
          // Two distinct, both-required constraints (do not conflate them):
          // - allowedAudiences restricts the token's `aud` claim. Per Microsoft's v2 token
          //   claims reference, `aud` is always the API's client ID (GUID); the App ID URI
          //   form is also accepted for compatibility with the access_as_user scope request.
          //   Mirrors lifecycle's hook-side audience list -- both values, not URI-only.
          // - defaultAuthorizationPolicy.allowedApplications restricts the token's
          //   `azp`/`appid` claim: which client application is trusted to have authenticated
          //   the caller, independent of audience.
          allowedAudiences: [
            entraClientId
            'api://${entraClientId}'
          ]
          defaultAuthorizationPolicy: {
            allowedApplications: [
              entraClientId
            ]
          }
        }
      }
    }
    login: {
      tokenStore: {
        enabled: true
      }
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
