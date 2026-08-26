# AI Observability Demo architecture

![AI Observability Demo architecture](diagrams/ai-observability-architecture.png)

[Edit the Excalidraw source](diagrams/ai-observability-architecture.excalidraw)

## Components

**Web App** provides Governed Model Comparison and Scientific Code Explainer. Both journeys use validated Entra identity.

The web host can use a separate approved location when the selected platform location has no App Service capacity.

**API Management** validates user tokens, authenticates to Foundry with managed identity, routes model requests, applies quotas, emits token metrics, and returns attribution metadata.

**Microsoft Foundry** hosts the two scenario projects and the GPT-5.4 and Claude Opus 5 model deployments. GPT-5.4 uses the `rai-ai-observability-demo` guardrail policy.

**The optional weather agent** configures GPT-5.4 with low reasoning. APIM validates this configuration without changing the model request.

The project-scoped model connection is private to `governed-model-comparison`. It does not appear under resource-level admin-connected models.

The agent can call one authenticated, read-only APIM MCP tool. APIM maps the tool to a protected weather REST operation in the web app.

**API Center** records the governed OpenAI, Claude, and direct protected-code APIs.

**Application Insights and Log Analytics** receive web, APIM, Foundry, App Service, and storage telemetry. The workbook displays model, team, user, token, latency, quota, and data-quality signals.

**Azure Cost Management and Storage** provide the resource-group budget and daily actual-cost export. Cost Management remains the billing source of truth.

**The FinOps snapshot workflow** uses managed identity to query daily actual cost, budget state, export state, and resource inventory. It writes aggregate records to three custom Log Analytics tables.

**The Azure Monitor dashboard with Grafana** combines operational telemetry and the FinOps snapshots. It uses the current viewer's Azure access and stores no separate data.

**Azure Policy and RBAC** apply region, tag, diagnostic, transport, user, and gateway controls.

See [Observability and cost management](observability-and-cost-management.md) for the signal map and operational gaps.
