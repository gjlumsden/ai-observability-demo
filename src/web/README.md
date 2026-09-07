# AI Observability Demo web application

Unified Express and Nunjucks web app styled with GOV.UK Frontend v5.

## Local development

```powershell
cd src\web
npm install
npm run dev
```

Do not use proprietary source code, secrets, or personal data in the demo journeys.

The web app displays provider token totals returned by APIM. It does not calculate
billed cost. APIM emits low-cardinality metrics and a separate pseudonymous usage
event. The web app does not send prompts, completions, raw object IDs, email
addresses, access tokens, subscription keys, or IP addresses to the cost
allocation pipeline.

## Authentication

The deployed app uses Azure App Service Authentication (Easy Auth) with
`WEBSITE_AAD_ENABLE_MISE=true`. The platform validates the token signature,
issuer, audience, and lifetime at the platform edge before a request reaches the
Node process. The app reads the resulting identity from the
`X-MS-CLIENT-PRINCIPAL-*` and `X-MS-TOKEN-AAD-*` request headers. Sign-in and
sign-out use the reserved `/.auth/*` paths.

The app runs no authentication library. It manages no session, cookie, or client
secret in app code. This is the Microsoft-approved MISE-compliant path for Node and
Express on App Service. App Service Authentication
activates when the postprovision hook populates the Entra client ID. For the platform
feature, see the public reference
[Azure App Service authentication and authorization](https://learn.microsoft.com/azure/app-service/overview-authentication-authorization).

There is no local authentication bypass. The sign-in route sanitizes the `returnTo`
target and falls back to a default path for an unsafe value. The app does not parse
or verify token signatures, issuers, audiences, or lifetimes. The platform validates
those. Protected routes cannot be exercised on a local development machine. The local
sign-in page states this.

For each protected action, the browser reads the provider access token from
`/.auth/me`. It sends that token to the same origin in the `Authorization` header.
This lets Easy Auth validate the POST before the request reaches Node. The helper keeps
the token only in function memory. It does not log or persist the token.

Provider access tokens can expire before the App Service session. Before a
downstream call, the app uses the platform expiry header to detect that condition.
The browser then calls `/.auth/refresh`, reads the renewed token from `/.auth/me`, and
retries the action once. A failed refresh stops the action and shows an error. The app
does not implement an OAuth exchange.
See [App Service token renewal](https://learn.microsoft.com/azure/app-service/configure-authentication-oauth-tokens).

The predeployment tests (`npm run test:auth-validation`, `npm run test:auth-logging`)
cover the forwarded-identity boundary, redirect sanitization, and token-renewal
request handling. They do not prove deployed token cryptography. A
separate postdeployment harness, `npm run postdeploy:auth-acceptance`, verifies token
acceptance against a deployed instance. It requires `EASYAUTH_ACCEPTANCE_BASE_URL` (an
`https` origin with no credentials, query, or fragment) and all five
`EASYAUTH_ACCEPTANCE_*_TOKEN` fixtures before any network call. A missing base URL, an
invalid base URL, or any missing fixture returns NOT RUN with exit code 2, never a
pass. It sends each token only to the same origin, treats only `401` or `403` as a
rejection, and never prints a token value or fragment.

## Environment variables

App-code settings:

- `PORT` - defaults to `3000`
- `APPLICATIONINSIGHTS_CONNECTION_STRING` - enables Azure Monitor OpenTelemetry auto-instrumentation
- `OTEL_SERVICE_NAME` - sets the stable Application Insights cloud role name
- `OTEL_TRACES_SAMPLER` - set to `always_on` in App Service so Application Insights retains every trace
- `MCP_WEATHER_KEY` - authenticates APIM to the read-only weather REST operation
- `APIM_BASE_URL` - base URL for API Management
- `APIM_PRESENTER_KEY` - governed model scenarios APIM subscription key

Platform authentication app settings:

- `WEBSITE_AAD_ENABLE_MISE` - set to `true` to enable the platform MISE token-validation engine
- `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET` - Easy Auth Entra client-secret setting name. The value is deployment-specific and is not published

The Bicep template and postprovision hook configure the client ID, issuer, audiences,
and delegated scope in `authsettingsV2`. The hook requests v2 access tokens through
`api.requestedAccessTokenVersion = 2`.

The hook also records `ENTRA_CLIENT_ID` and `ENTRA_TENANT_ID` in App Service settings.
Those copies are deployment metadata, not settings that Express or Easy Auth reads
automatically. Changing them alone does not update the identity provider.
The separate `ENTRA_CLIENT_ID` value in the azd environment selects the registration
that the provisioning hook reuses.

App Service Authentication replaces the previous library sign-in. The app no
longer reads `SESSION_SECRET`, `ENTRA_CLIENT_SECRET`, `ENTRA_REDIRECT_URI`, or
`ENTRA_SCOPES`. The previous `@azure/msal-node`, `express-session`, and
`cookie-parser` dependencies are removed.

## Weather operation

`POST /api/weather/forecast` provides public demo forecast data to APIM.

The operation requires `x-mcp-key`. The deployment hooks generate the key and store it in App Service and an APIM named value.

APIM exposes the REST operation as the native `get_weather_forecast` MCP tool. Foundry connects only to the APIM MCP endpoint.

The operation uses public data for the demo. It is not an official forecast source.

## Deployment

The App Service Linux Node runtime uses `npm start` from `package.json`.

```powershell
azd deploy web
```
