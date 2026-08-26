# AI Observability Demo web application

Unified Express and Nunjucks web app styled with GOV.UK Frontend v5.

## Local development

```powershell
cd src\web
npm install
npm run dev
```

Do not use proprietary source code, secrets, or personal data in the demo journeys.

## Environment variables

- `PORT` - defaults to `3000`
- `APPLICATIONINSIGHTS_CONNECTION_STRING` - enables Azure Monitor OpenTelemetry auto-instrumentation
- `OTEL_SERVICE_NAME` - sets the stable Application Insights cloud role name
- `OTEL_TRACES_SAMPLER` - set to `always_on` in App Service so Application Insights retains every trace
- `MCP_WEATHER_KEY` - authenticates APIM to the read-only weather REST operation
- `SESSION_SECRET` - Express session secret
- `APIM_BASE_URL` - base URL for API Management
- `APIM_PRESENTER_KEY` - governed model scenarios APIM subscription key
- `ENTRA_CLIENT_ID`, `ENTRA_TENANT_ID`, `ENTRA_CLIENT_SECRET` - MSAL confidential client settings
- `ENTRA_REDIRECT_URI` - optional callback URI
- `ENTRA_SCOPES` - space- or comma-separated scopes; the deployed application uses `access_as_user`

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
