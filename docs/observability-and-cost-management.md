# Observability and cost management

## Purpose

This document explains how the platform observes AI usage, application health, model behavior, and billed cost.

It also compares the implementation with Microsoft AI Landing Zone and Azure Well-Architected Framework guidance.

The AI Landing Zone is a preview reference architecture, not a compliance standard.
Assess each Azure feature by its documented support status.

## Four signal planes

### Usage and control plane

API Management is the control point for model requests.

It provides:

- Entra token validation for signed-in users.
- Restricted subscription keys for generated team traffic.
- Team, user, model, project, API, operation, product, and subscription attribution.
- Per-minute and daily token limits.
- Provider-reported token metrics.
- Correlation IDs.
- Prompt Shield and completion-safety enforcement.

These signals are operational. They are available before billing data.

The demo uses only four fixed user values. Azure Monitor custom metric dimensions have cardinality limits and can discard new values after limits are reached.

For production, keep metric dimensions low-cardinality. Put individual user and session attribution in structured logs.

The demo requests minimal model reasoning:

- GPT-5.4 uses `reasoning.effort: low`, its lowest nonzero supported level.
- Claude Opus 5 uses `thinking.type: adaptive` with `output_config.effort: low`.

### Application and resource plane

The Azure Monitor OpenTelemetry Distro sends application telemetry to Application Insights and Log Analytics.
The web app does not enable the App Service codeless agent, which prevents duplicate request and dependency records.
Dependency spans contain route, host, status, and duration data. They exclude prompts, model responses, and backend error text.

The current sinks contain:

- Web requests, dependencies, console logs, and platform logs.
- APIM requests, backend dependencies, exceptions, and gateway logs.
- Foundry request, audit, resource metric, and Content Safety activity.
- Storage metrics and blob operation logs.

The workload Log Analytics workspace is the primary operational log sink.

The current workspace retains interactive data for 30 days.

The subscription also applies a central storage diagnostic policy. This creates a second storage diagnostic destination.

### Quality and safety plane

Foundry observability includes evaluation, monitoring, and tracing.

The two core application journeys use model endpoints. The optional weather demo uses a Foundry prompt agent with one MCP tool.

Therefore:

- Model resource metrics are expected.
- Foundry request and audit logs are expected.
- APIM safety exceptions are expected.
- Agent traces are expected only after the optional weather agent runs.
- Continuous quality evaluation and model-drift alerts are not implemented.

Prompt Shields and Protected Material for Code provide runtime safety signals. They do not replace formal evaluation.

### Financial plane

Azure Cost Management is the source of billed cost.

The platform provides:

- Stable workload, project, cost-centre, and environment tags.
- A resource-group monthly budget.
- A daily actual-cost export.
- A daily managed-identity snapshot of actual cost, budget state, export state, and resource inventory.
- A managed identity for the export.
- A storage role assignment for the export identity.
- A private export container with shared-key access disabled.
- Three custom Log Analytics tables for the Grafana dashboard.

The budget has no recipients unless deployment parameters provide email addresses.

APIM token limits are immediate controls. A Cost Management budget is not a hard stop.

Project-level Foundry cost attribution is preview and does not cover every Marketplace-billed model. Reconcile project tags with resource and meter data.

## Signal map

| Source | Signal | Destination | Primary use |
| --- | --- | --- | --- |
| Web application | Requests, dependencies, exceptions | Application Insights and Log Analytics | User journey health |
| App Service | HTTP, console, application, platform logs | Log Analytics | Runtime diagnosis |
| APIM gateway | Request result, latency, backend dependency | Application Insights | Gateway diagnosis |
| APIM resource logs | Gateway logs | Log Analytics `ApiManagementGatewayLogs` | Detailed gateway investigation and request analytics |
| APIM AI policy | Prompt, completion, and total token metrics | Application Insights `customMetrics` and Log Analytics `AppMetrics` | Usage attribution |
| APIM AI policy | Prompt Shield and Content Safety failures | Application Insights requests and exceptions | Safety operations |
| Foundry resource | Request, audit, and resource metrics | Log Analytics and Azure Monitor metrics | Model-native operations |
| Protected-code API | Detection result and citations | Application response and `guardrail.decision` event | Direct guardrail verification |
| Workbook | KQL over Application Insights | Azure Workbook | Presenter and operator dashboard |
| Cost Management | Actual billed cost | Cost Analysis, budget, export | Financial control |
| FinOps snapshot workflow | Daily actual cost, budget, export, and resource state | `AIObservabilityCostDaily_CL`, `AIObservabilityFinOpsState_CL`, and `AIObservabilityResourceInventory_CL` | Unified reporting bridge |
| Azure Monitor dashboard with Grafana | KQL over operational and FinOps tables | Azure portal | Unified operational and financial view |

## APIM telemetry configuration and destinations

The deployment applies three separate APIM telemetry configurations. Each configuration has a different purpose and destination.

| Configuration | Sampling | Data | Destination | User interface |
| --- | ---: | --- | --- | --- |
| APIM Application Insights diagnostic | 100% | Requests, backend dependencies, errors, correlation, and custom token metrics | Workspace-based Application Insights | Application Insights, workbook, and Grafana |
| APIM Azure Monitor diagnostic | 100% | Client IP, masked URL context, and LLM model and token metadata | Azure Monitor resource-log pipeline | APIM Analytics and Log Analytics |
| APIM resource diagnostic setting | 100% | `GatewayLogs`, `GatewayLlmLogs`, and `AllMetrics` | Workload Log Analytics workspace | APIM Analytics, Logs, and Grafana |

### Application Insights destination

The `applicationinsights` APIM diagnostic uses the APIM Application Insights logger.

It applies:

- Fixed 100% sampling.
- W3C correlation.
- `allErrors` logging.
- Custom metrics from `llm-emit-token-metric`.
- No client IP logging.
- Zero request and response body bytes for frontend and backend messages.

The resulting workspace tables include:

- `AppRequests` for APIM requests.
- `AppDependencies` for model and Content Safety backends.
- `AppExceptions` for APIM failures.
- `AppMetrics` for prompt, completion, and total-token metrics.

The Application Insights experience, usage workbook, and Grafana dashboard query these tables.

### Log Analytics destination

The `send-to-log-analytics` resource diagnostic uses resource-specific tables.

It enables:

- `GatewayLogs` to `ApiManagementGatewayLogs`.
- `GatewayLlmLogs` to `ApiManagementGatewayLlmLog`.
- `AllMetrics` to the `AzureMetrics` Log Analytics table.
- `logAnalyticsDestinationType: Dedicated`.

`ApiManagementGatewayLogs` supports request, API, operation, product, subscription, user-owner, result, latency, region, and caller-IP analysis.

`ApiManagementGatewayLlmLog` supports model name, deployment, API version, prompt tokens, completion tokens, total tokens, request count, and TPM analysis.

Native APIM metrics remain available in Azure Monitor Metrics independently of the diagnostic setting.

### Native APIM Analytics

The standard APIM Analytics sections use gateway traffic and configured APIM dimensions:

- Timeline.
- Geography.
- APIs.
- Operations.
- Products.
- Subscriptions.
- Users.
- Requests.

The Language models section uses `ApiManagementGatewayLlmLog`.

The deployment creates three synthetic APIM users and assigns them as subscription owners:

- Presenter Demo.
- Research Team.
- Engineering Team.

These owners populate the native **Users** breakdown. They do not replace Entra validation or the four `x-demo-user-id` values used for detailed workbook attribution.

### Native percentage display limitation

The `ms.portal.azure.com` APIM Language models view currently renders each green `100%` strip as `10,000%`.

The built-in workbook supplies a whole-number value of `100`. The current percentage formatter treats that value as a fraction and multiplies it by 100.

This display defect does not affect the absolute token, request, model, API version, or TPM values.

Do not change APIM diagnostic sampling from 100% to 1% to make the strip show `100%`. That change would discard approximately 99% of diagnostic records.

Until the built-in workbook is corrected:

- Use the absolute values above each strip.
- Use the model, API version, and subscription breakdown charts.
- Use the documented KQL queries, workbook, or Grafana dashboard for calculations.

### Privacy boundary

The LLM diagnostic enables default metadata logs only.

It does not configure `largeLanguageModel.requests` or `largeLanguageModel.responses`. Therefore:

- `RequestMessages` remains empty.
- `ResponseMessages` remains empty.
- Prompts are not retained.
- Completions are not retained.
- Query parameters are hidden in the Azure Monitor APIM diagnostic.

Enabling prompt or completion logging later would change this privacy boundary and increase ingestion cost.

This boundary applies to APIM diagnostics only. Foundry agent traces can contain user input, model output, tool arguments, and tool results.

Restrict Foundry trace access through Azure RBAC. Use only demo-safe input for this demo.

### Destinations not changed by this configuration

The APIM telemetry change does not alter:

- Foundry resource diagnostics.
- App Service OpenTelemetry.
- Cost Management exports or FinOps snapshots.
- Storage diagnostics.
- Content Safety enforcement.
- APIM authentication, quotas, routing, or subscription keys.

## Expected evidence

Verify these signals after deployment:

- Application Insights contains web and APIM requests, dependencies, failures, and guardrail decisions.
- Log Analytics contains application, APIM, Foundry, App Service, and storage records.
- APIM language-model logs contain model and token metadata without prompt or completion bodies.
- Foundry contains model metrics and agent traces after the optional weather agent runs.
- The workbook source matches `infra/workbooks/monitoring-workbook.json`.
- The Grafana source matches `infra/dashboards/grafana-dashboard.json`.
- Cost Management contains the budget, export, and billed resource costs.
- The FinOps workflow writes cost, state, and inventory snapshots.

## Portal workflow

### Check the user journey

1. Open Application Insights.
2. Open **Transaction search** or **Failures**.
3. Filter to the web role.
4. Run one fresh model comparison before opening **Application Map**.
5. Follow the operation ID through the web dependency, APIM request, and Foundry dependency.

### Check the unified dashboard

1. Open **Azure Monitor**.
2. Open **Dashboards with Grafana**.
3. Select **AI Observability and Cost**.
4. Review data freshness before using totals.
5. Use the same time range for operational comparisons.
6. Open Cost Analysis for billing detail and reconciliation.

### Check gateway behavior

1. Open API Management.
2. Open the governed APIM gateway query in Log Analytics.
3. Review request volume, response codes, and latency.
4. Use the workload workbook for model token and attribution views.
5. Use Application Insights for dependency and exception detail.

Use the native **Language models** tab for request and token analysis. The deployment enables token metadata only and does not enable prompt or completion messages.

### Check model-native behavior

1. Open the Foundry resource metrics.
2. Review model requests, input tokens, output tokens, errors, latency, and throttling.
3. Use Foundry `RequestResponse` logs for resource-level investigation.
4. Do not expect agent traces for the model-only scenarios.
5. Run the optional weather agent before reviewing agent and MCP traces.

### Check the weather MCP agent

1. Open `weather-forecast-agent` in the Foundry agents view.
2. Select **Plan Balado festival operations**.
3. Confirm the agent calls only `get_weather_forecast`.
4. Confirm the response reads as an operational assessment and does not name the tool provider.
5. Review the resulting agent and MCP tool-call traces.

APIM exposes the tool through a native MCP server. The MCP tool maps to a protected REST operation in the web app.

### Weather agent attribution

The weather flow uses separate records for separate purposes:

- The outer APIM agent endpoint records the validated user, request result, and latency.
- The internal APIM model endpoint emits GPT-5.4 prompt, completion, reasoning, and total-token metrics.
- Those model tokens use Team `Agents`, User `weather-forecast-agent`, Product `Agents`, and Subscription `weather-agent-sub`.
- The APIM MCP endpoint records tool discovery and calls in `ApiManagementGatewayMCPLog`.

The outer agent endpoint does not emit token metrics. This prevents double counting the same model use.

Foundry Agent Service does not propagate the validated application user into its internal model-gateway call. Therefore, model tokens are allocated to the agent workload, not directly to an individual user.

The Foundry project uses a project-managed-identity Application Insights connection. The project identity and weather-agent identity have the Monitoring Metrics Publisher role.

Foundry exports agent, model, and tool spans, but it does not export every internal transport parent span. Use the W3C `OperationId`, response ID, and span IDs to correlate the transaction. Parent-tree gaps at the managed Foundry boundary are expected and cannot be filled by application instrumentation.

### Check usage attribution

1. Open the **AI Observability usage and cost governance** workbook.
2. Select a fixed time range.
3. Filter by team, user, model, provider, or project.
4. Review the data-quality table before using totals.

### Check billed cost

1. Open Cost Analysis at the workload resource-group scope.
2. Use the same date range as the operational review.
3. Group by service, resource, meter, and tag.
4. Review the budget.
5. Review the export run history and exported files.

## Useful KQL

### Token attribution

```kusto
customMetrics
| where timestamp > ago(24h)
| where name == "Total Tokens"
| extend
    Team = tostring(customDimensions["Team"]),
    User = tostring(customDimensions["User"]),
    Model = tostring(customDimensions["Model"]),
    Project = tostring(customDimensions["Project"])
| summarize
    Requests = toint(sum(valueCount)),
    Tokens = toint(sum(valueSum))
  by Team, User, Model, Project
| order by Tokens desc
```

### Gateway reliability

```kusto
union isfuzzy=true
(
  ApiManagementGatewayLogs
  | project
      TimeGenerated,
      ResponseCode = toint(ResponseCode),
      DurationMilliseconds = tolong(TotalTime),
      RequestUrl = tostring(Url)
),
(
  AzureDiagnostics
  | where ResourceProvider == "MICROSOFT.APIMANAGEMENT"
  | where Category == "GatewayLogs"
  | project
      TimeGenerated,
      ResponseCode = toint(responseCode_d),
      DurationMilliseconds = tolong(DurationMs),
      RequestUrl = tostring(url_s)
)
| where TimeGenerated > ago(24h)
| where RequestUrl has "/models/" or RequestUrl has "/guardrails/"
| extend Route = tostring(parse_url(RequestUrl).Path)
| summarize
    Requests = count(),
    SuccessRate = round(100.0 * countif(ResponseCode between (200 .. 399)) / count(), 2),
    P95Milliseconds = round(percentile(DurationMilliseconds, 95), 0)
  by Route, ResponseCode
| order by Requests desc
```

### APIM Analytics coverage

```kusto
ApiManagementGatewayLogs
| where TimeGenerated > ago(24h)
| summarize
    Requests = count(),
    APIs = dcountif(ApiId, isnotempty(ApiId)),
    Operations = dcountif(OperationId, isnotempty(OperationId)),
    Products = dcountif(ProductId, isnotempty(ProductId)),
    Subscriptions = dcountif(ApimSubscriptionId, isnotempty(ApimSubscriptionId)),
    Users = dcountif(UserId, isnotempty(UserId)),
    CallerIPs = dcountif(CallerIpAddress, isnotempty(CallerIpAddress)),
    GatewayRegions = dcountif(Region, isnotempty(Region))
```

### APIM LLM metadata and privacy

```kusto
ApiManagementGatewayLlmLog
| where TimeGenerated > ago(24h)
| summarize
    Requests = count(),
    Models = dcountif(ModelName, isnotempty(ModelName)),
    APIVersions = dcountif(ApiVersion, isnotempty(ApiVersion)),
    PromptTokens = sum(PromptTokens),
    CompletionTokens = sum(CompletionTokens),
    TotalTokens = sum(TotalTokens),
    RequestMessageRecords = countif(isnotempty(tostring(RequestMessages))),
    ResponseMessageRecords = countif(isnotempty(tostring(ResponseMessages)))
```

Both message-record counts must remain zero for the documented privacy boundary.

### Foundry resource logs

```kusto
AzureDiagnostics
| where TimeGenerated > ago(24h)
| where ResourceProvider == "MICROSOFT.COGNITIVESERVICES"
| summarize Rows = count() by Category, bin(TimeGenerated, 15m)
| order by TimeGenerated desc
```

## Why values differ

APIM, Foundry, and Cost Management measure different things.

| View | Measures | Typical delay |
| --- | --- | --- |
| APIM | Provider-reported tokens and request controls | Seconds to minutes |
| Application Insights | Requests, dependencies, custom metrics, exceptions | Seconds to minutes |
| Foundry metrics | Resource and model operations | Minutes |
| Cost Management | Rated billing meters after pricing and discounts | Hours |
| Cost export | Detailed actual-cost records | Daily |
| FinOps snapshot | Aggregated Cost Management and resource state | Daily |

Do not treat a token metric as an invoice line.

Claude uses consumption-unit billing. OpenAI meters can separate input, cached input, and output tokens.

Retries, filtered requests, model reasoning, caching, rounding, private pricing, and time boundaries can change totals.

For showback, compare operational usage with billed cost over a fixed period.

For chargeback, define an allocation rule and retain both usage and billing evidence.

## AI Landing Zone comparison

| Checklist item | Status | Current implementation | Gap or next step |
| --- | --- | --- | --- |
| CO-R1: estimate and understand Foundry cost | Partial | Budget, tags, Cost Analysis, and exports exist | Add a maintained pricing estimate and cost model |
| CO-R2: consider PTU and pay-as-you-go mix | Not implemented | Global Standard pay-as-you-go deployments | Evaluate PTU only after workload demand becomes predictable |
| CO-R3: consider deployment types | Aligned for demo | Global model deployments are used | Reassess deployment type against data-residency and pricing requirements |
| CO-R4: shut down nonproduction compute | Not applicable | The workload uses managed PaaS services | Apply when dedicated compute is introduced |
| G-R1: automate AI governance with policy | Partial | Audit policies exist | Add model allowlist and AI-specific policies before enforcing deny |
| G-R4: use Content Safety | Aligned | Prompt Shields, Content Safety, and protected-code checks are active | Add formal safety evaluation evidence |
| G-R5: govern model availability | Not implemented | Bicep fixes deployed model names | Add an audited model allowlist policy |
| I-R1: managed identity and least privilege | Partial | APIM and cost export use managed identity | Replace remaining APIM subscription-key distribution where practical |
| I-R3: prefer Entra authentication | Partial | Users use Entra; Foundry local auth is disabled | Product subscription keys remain for gateway attribution |
| M-R1: monitor models, resources, and data | Partial | Operational model, gateway, application, and cost signals exist | Define workload KPIs and quality objectives |
| M-R2: use Azure Monitor baseline alerts | Not implemented | No action group or Azure Monitor alert rules exist | Add alert routing and tested alert rules |
| M-R3: monitor generative AI performance | Partial | Tokens, errors, safety, and latency are monitored | Add evaluation, feedback, and distributed tracing if the workload advances |
| M-R4: send diagnostics to Log Analytics | Aligned for deployed services | Web, APIM, Foundry, and storage diagnostics are configured | Define retention, table plans, and ingestion controls |
| M-R5: monitor drift | Not implemented | No quality or drift evaluation exists | Add scheduled evaluation with approved datasets |
| R-R2 and R-R3: plan quota and capacity | Partial | Model quota was validated and adjusted | Add repeatable quota preflight and capacity thresholds |
| R-R4: organize billing boundaries | Partial | One Foundry resource contains two projects | Use separate Foundry resources where workload billing or isolation requires it |

## Well-Architected assessment

| Pillar | Current strengths | Main trade-off or gap |
| --- | --- | --- |
| Reliability | Health endpoint, request logs, dependency logs, P95 latency, two model providers | One web instance, no availability test, no proactive alerts, no failover |
| Security | Entra validation, managed identity, disabled Foundry local auth, no prompt-body logging | Public gateway, application secret, subscription keys, deferred MISE work |
| Cost Optimization | Tags, budget, completed exports, token quotas, global deployments, daily cost snapshots | No budget recipients, anomaly workflow, forecast review, or PTU analysis |
| Operational Excellence | Bicep, azd, diagnostic settings, workbook, Grafana dashboard, runbook, correlation IDs | No action group, alert runbook, quality gate, or automated evaluation |
| Performance Efficiency | Model latency and token metrics, quota controls | No load target, autoscale test, capacity alert, or formal performance objective |

## Prioritized improvements

### Production requirements

1. Complete MISE remediation.
2. Define service objectives for availability, latency, error rate, token use, and cost.
3. Add an action group and tested alerts for availability, APIM failure rate, P95 latency, model errors, and throttling.
4. Add budget recipients and an anomaly review process.
5. Add an Application Insights Standard availability test.
6. Define Log Analytics retention, archive, daily-cap, and ingestion-transformation policies.
7. Add model allowlist governance in audit mode.
8. Add quality, safety, and regression evaluation with approved datasets.
9. Move user-level attribution from custom metrics to structured logs before user cardinality exceeds the bounded demo set.

### When scale becomes predictable

1. Compare pay-as-you-go cost with provisioned throughput or commitment tiers.
2. Define a chargeback allocation rule.
3. Replace the demo aggregate snapshot with a governed FinOps ingestion process when detailed allocation is required.
4. Review project and Foundry resource boundaries against billing ownership.
5. Add autoscale and capacity testing.

## APIM tier position

Basic v2 supports the AI gateway policies used by this demo and has an SLA.

Microsoft positions Basic v2 for development and testing. Assess Standard v2 or Premium v2 for production throughput, private backend connectivity, and network isolation.

The v2 tiers do not provide native multi-region gateway deployment. A production regional-failure strategy needs explicit design.

## References

- [AI Landing Zones](https://azure.github.io/AI-Landing-Zones/)
- [AI Landing Zone design checklist](https://azure.github.io/AI-Landing-Zones/architecture/design-checklist/)
- [Baseline Microsoft Foundry architecture in an Azure landing zone](https://learn.microsoft.com/azure/architecture/ai-ml/architecture/baseline-microsoft-foundry-landing-zone)
- [Observability in generative AI](https://learn.microsoft.com/azure/foundry/concepts/observability)
- [Observability in API Management](https://learn.microsoft.com/azure/api-management/observability)
- [Plan and manage costs for Microsoft Foundry](https://learn.microsoft.com/azure/foundry/concepts/manage-costs)
- [Application Insights Well-Architected guidance](https://learn.microsoft.com/azure/well-architected/service-guides/application-insights)
- [Log Analytics Well-Architected guidance](https://learn.microsoft.com/azure/well-architected/service-guides/azure-log-analytics)
- [Collect and review cost data](https://learn.microsoft.com/azure/well-architected/cost-optimization/collect-review-cost-data)
- [Visualize Azure Monitor data with Grafana](https://learn.microsoft.com/azure/azure-monitor/visualize/visualize-grafana-overview)
- [Logs Ingestion API in Azure Monitor](https://learn.microsoft.com/azure/azure-monitor/logs/logs-ingestion-api-overview)
- [Azure OpenAI reasoning models](https://learn.microsoft.com/azure/ai-services/openai/how-to/reasoning)
- [Claude models in Microsoft Foundry](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/claude-models)
- [Connect agents to MCP servers](https://learn.microsoft.com/azure/foundry/agents/how-to/tools/model-context-protocol)
