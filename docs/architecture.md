# AI Observability Demo architecture

![AI Observability Demo architecture](diagrams/ai-observability-architecture.png)

[Edit the Excalidraw source](diagrams/ai-observability-architecture.excalidraw)

## Resource-group topology

The deployment uses two sibling resource groups:

```text
Main demo resource group
├─ Web App, API Management, Foundry, API Center, and monitoring
├─ Event Hubs Standard with Capture
├─ usage storage, Key Vault, and the Python usage processor
├─ AIRequestUsage_CL and AICostAllocation_CL
├─ workload budget, two Grafana dashboards, and one Workbook
└─ exact APIM and Foundry resource IDs used as allocation allowlists

Sibling <main-resource-group>-finops resource group
├─ Microsoft FinOps hubs v14
├─ Data Factory and Premium_LRS ADLS Gen2 storage
├─ daily month-to-date and monthly previous-month FOCUS exports
└─ support resource-group budget and export failure monitoring
```

The managed FOCUS exports monitor exactly the main demo resource group. The
support resource group is not part of the exported workload. The processor also
accepts usage only from the exact deployed APIM resource group and Foundry
resource IDs. Other resource, resource-group, subscription, and billing scopes
are rejected.

## Components

**Web App** provides Governed Model Comparison and Scientific Code Explainer. Both journeys use validated Entra identity.

The web host can use a separate approved location when the selected platform location has no App Service capacity.

**API Management** validates user tokens, authenticates to Foundry with managed
identity, routes model requests, applies quotas, and returns attribution
metadata. Its token metrics use exactly API ID, Subscription ID, Team, Model,
and Attribution Mode. It sends complete token categories in a structured,
pseudonymous event to Event Hubs.

**Microsoft Foundry** hosts the two scenario projects and the GPT-5.4 and Claude Opus 5 model deployments. GPT-5.4 uses the `rai-ai-observability-demo` guardrail policy.

**The optional weather agent** configures GPT-5.4 with low reasoning. APIM validates this configuration without changing the model request.

The project-scoped model connection is private to `governed-model-comparison`. It does not appear under resource-level admin-connected models.

The agent can call one authenticated, read-only APIM MCP tool. APIM maps the tool to a protected weather REST operation in the web app.

**API Center** records the governed OpenAI, Claude, and direct protected-code APIs.

**Application Insights and Log Analytics** receive web, APIM, Foundry, App
Service, and storage telemetry. `AIRequestUsage_CL` keeps individual, project,
and full provider token categories. `AICostAllocation_CL` keeps append-only
FOCUS allocation runs and external Claude CCU context.

**Event Hubs Capture and usage storage** keep a 400-day pseudonymous archive.
The storage account also keeps Function host data, checkpoints, processor state,
and safe quarantine records. Archive records can be replayed after an ingestion
failure.

**The Python usage processor** uses managed identity. It writes directly through
an Azure Monitor data collection rule (DCR). It does not have access to the HMAC
secret. It validates scope, deduplicates usage, quarantines malformed records,
processes completed FOCUS datasets by path and ETag, and allocates cost.

**Microsoft FinOps hubs and Cost Management** provide delayed resource-group
FOCUS actuals. A versioned rate card provides request estimates. FOCUS
`BilledCost` and `EffectiveCost` are allocated with the request estimates as
weights. Unmatched resource-group cost stays unallocated.

Claude CCU actual cost can be absent from a resource-group FOCUS export. The
processor records this state as unavailable with null actual-cost fields. It
does not report zero. A separate subscription Cost Management query provides
Claude CCU external context. That context is excluded from demo totals and is
never allocated to a team or individual.

**Azure Monitor dashboards with Grafana** provide two views. **AI Usage and Cost
Attribution** is the decision view. **Attribution Pipeline Operations** is the
operator view. The **AI Usage and Cost Investigation** Workbook provides request,
allocation, exception, evidence, reconciliation, and external-context
drill-downs. Subject panels need restricted access. Friendly aliases are not
stored by this demo; an authorized mapping must remain external.

**Azure Policy and RBAC** apply region, tag, diagnostic, transport, user, and gateway controls.

See [Observability and cost management](observability-and-cost-management.md) for the signal map and operational gaps.
