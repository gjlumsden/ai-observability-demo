# Observability and cost management

## Purpose

This document explains the demo usage, cost, privacy, and reporting model.
Azure Cost Management remains the financial source. Provider responses remain
the token source.

The implementation is a demo. It does not provide a finance-approved chargeback
service or production identity directory.

## Locked topology and scope

The deployment creates two sibling resource groups:

| Resource group | Contents | Cost role |
| --- | --- | --- |
| Main demo resource group | Web App, APIM, Foundry, monitoring, Event Hubs, usage storage, Key Vault, Function, budget, dashboards, and Workbook | The only workload scope |
| `<main-resource-group>-finops` | Microsoft FinOps hubs v14, Data Factory, ADLS Gen2 storage, support budget, and export monitoring | Processes FOCUS data for the main group |

FinOps managed FOCUS exports monitor exactly the main demo resource group. The
deployment creates one daily month-to-date export and one monthly previous-month
export. Both use FOCUS 1.2 data in Parquet format with Snappy compression.

The support resource group is not part of the monitored dataset. Every usage
query also applies the exact main resource-group ID and exact deployed Foundry
resource ID. APIM is the only accepted usage source. Usage from another APIM,
Foundry resource, resource group, subscription scope, or billing scope is not
eligible for allocation.

## Usage and financial authority

The reporting terms have distinct meanings:

| Term | Meaning |
| --- | --- |
| Usage | Provider-reported token data emitted by APIM |
| Rate-card estimate | A request estimate from the versioned rate card; it is not an invoice value |
| Resource-group FOCUS actual | The authoritative `BilledCost` and `EffectiveCost` values for the locked workload scope |
| Allocated billed cost | A share of resource-group FOCUS `BilledCost`, weighted by eligible request estimates |
| Allocated effective cost | A share of resource-group FOCUS `EffectiveCost`, weighted by eligible request estimates |
| Unallocated resource-group cost | A FOCUS amount without a reliable eligible usage match |
| Resource-group Claude CCU status | The actual CCU amount, or an explicit unavailable state, from the resource-group FOCUS data |
| Subscription-wide Claude CCU context | A separate Cost Management query for operator context |

`BilledCost` is the invoiced charge before some commitment effects. `EffectiveCost`
represents amortized commitment and discount effects when Azure supplies them.
The processor allocates both fields independently. For each source bucket:

```text
allocated BilledCost + unallocated BilledCost = source BilledCost
allocated EffectiveCost + unallocated EffectiveCost = source EffectiveCost
```

An allocation uses provider-aware rate-card estimates as weights. It does not
infer a private price or convert an estimate into an actual charge. Unmatched
cost remains explicit. Correction runs are append-only and retain the source
path and ETag.

## Claude CCU boundary

Claude billing uses Claude Consumption Units (CCUs). A resource-group FOCUS
export can omit the Marketplace CCU row even when subscription Cost Management
shows a Claude charge.

An omitted row means that the resource-group actual is unavailable. It does not
mean that the actual cost is zero. The processor writes
`actual-unavailable-at-resource-group-scope` with null actual-cost fields and
`IncludedInWorkloadTotal=false`.

The processor also queries subscription Cost Management for exact Anthropic
Claude CCU meters. These records use:

- `SourceScope='subscription'`
- `AttributionStatus='external-unallocated'`
- `IncludedInWorkloadTotal=false`
- no team or subject allocation

The subscription value can include other workloads. It is excluded from every
demo total. The processor never uses it as an allocation fallback, weight, or
denominator.

## Metric and structured-event split

APIM token metrics use exactly these configured dimensions:

1. `API ID`
2. `Subscription ID`
3. `Team`
4. `Model`
5. `Attribution Mode`

The metric dimensions are bounded and suitable for fast operational charts.
They do not contain `User`, `Project`, `Operation ID`, or `Product ID`.

`AIRequestUsage_CL` is the structured request ledger. It contains:

- a stable team ID and HMAC-derived subject ID;
- project, operation, correlation, trace, provider, model, and deployment data;
- input, cached input, uncached input, cache-write, output, reasoning, visible
  output, thinking, and total token values when the provider supplies them;
- request outcome, token quality, rate-card version, estimate, and archive
  evidence.

Use `AIRequestUsage_CL` for individual, project, and complete token analysis.
Do not derive individual values from metrics.

## Pseudonym and privacy boundary

APIM creates `SubjectId` before the event enters Event Hubs. It applies
HMAC-SHA256 to the tenant ID, subject kind, and validated subject. HMAC is a
keyed digest that gives a stable pseudonym without retaining the source identity.

The versionless HMAC secret is stored in Key Vault. A temporary deployment
identity creates or reuses it. APIM reads it through a Key Vault-backed secret
named value. The usage Function has no access to the HMAC secret.

The usage and cost pipeline retains none of these values:

- prompts or completions;
- request or response bodies;
- raw Entra object IDs or email addresses;
- access tokens or APIM subscription keys;
- client IP addresses.

The `RawUsage` field contains only known numeric provider usage fields. A
quarantine record stores a payload digest, payload size, validation reason, and
Event Hubs position. It does not store the malformed payload.

APIM diagnostics also keep request and response body byte counts at zero.
`RequestMessages` and `ResponseMessages` must remain empty. Foundry agent traces
have a separate boundary and can contain agent input, output, and tool data.
Use only approved demo data and restrict Foundry trace access.

## Processing and retention

```text
APIM
├─ bounded token metrics ──────────────────────> Application Insights
└─ pseudonymous usage event ─> Event Hubs
                                ├─ Function consumer ─> direct DCR ingestion
                                │                     ├─ AIRequestUsage_CL
                                │                     └─ AICostAllocation_CL
                                └─ Capture ──────────> 400-day usage archive

FinOps support resource group
└─ scoped managed FOCUS exports ─> Function allocation timer ─> DCR

Subscription Cost Management
└─ Claude CCU context query ─────> excluded external rows ─────> DCR
```

Event Hubs retains live events for seven days. Event Hubs Capture writes the
pseudonymous archive to Blob Storage. The processor can replay Capture records
after a direct DCR ingestion failure.

The usage storage account also provides:

- Function host and secret containers;
- Function checkpoint queues and tables;
- the processor work queue;
- ETag-based processor state;
- the quarantine container.

Malformed or out-of-scope records go to quarantine without blocking valid
records. State records prevent duplicate completed work. A changed FOCUS ETag
creates a traceable correction run.

The Function sends records directly to the Azure Monitor Logs Ingestion API
through a DCR. `AIRequestUsage_CL` retains data for 120 days.
`AICostAllocation_CL` retains data for 400 days. Capture and quarantine blobs
have a 400-day lifecycle rule.

The FOCUS allocation timer runs daily after the expected export window. A
separate timer records subscription Claude CCU context. These timers do not make
Cost Management data immediate.

## Signal map

| Source | Data | Destination | Use |
| --- | --- | --- | --- |
| Web App | Requests, dependencies, and exceptions | Application Insights and Log Analytics | Journey health |
| APIM diagnostic | Requests, dependencies, failures, and bounded token metrics | Application Insights | Fast operations |
| APIM resource logs | Gateway and LLM metadata | Log Analytics | Gateway investigation |
| APIM usage event | Pseudonymous complete usage data | Event Hubs and Capture | Allocation evidence |
| Usage Function | Validated request rows | `AIRequestUsage_CL` | Individual and token analysis |
| Managed FOCUS export | Locked resource-group actuals | FinOps hub storage | Financial authority |
| Allocation Function | Allocated and unallocated cost rows | `AICostAllocation_CL` | Cost reporting |
| Cost Management query | Subscription Claude CCU total | Excluded allocation rows | External operator context |
| Foundry | Model metrics and optional agent traces | Azure Monitor | Model-native cross-check |

## Reporting surfaces

### AI Usage and Cost Attribution

The Azure Monitor dashboard resource is `AI-Observability-and-Cost`. Its
displayed Grafana dashboard title is **AI Usage and Cost Attribution**.

Use it for:

- requests, tokens, and rate-card estimates;
- allocated billed and effective cost;
- unallocated resource-group cost and reconciliation;
- team, provider, model, project, and token-composition trends;
- restricted pseudonymous individual usage;
- resource-group Claude CCU status;
- separate subscription-wide Claude CCU external context.

The subject filter and individual panels require restricted access. Subject IDs
are pseudonyms, not public identifiers. This repository stores no friendly alias
map. If an authorized team needs names, keep that mapping in an external,
access-controlled system.

### Attribution Pipeline Operations

The Azure Monitor dashboard resource is `Attribution-Pipeline-Ops`. The
displayed title is **Attribution Pipeline Operations**. It contains no
individual identity.

Use it for Event Hubs ingress, Capture status, processor lag, allocation state,
quarantine growth, DCR signals, FOCUS freshness, export failures, scope
rejections, replay handling, and reconciliation residuals.

### AI Usage and Cost Investigation Workbook

Use the Workbook for filtered drill-downs:

- raw request and allocation ledgers;
- request and allocation exceptions;
- request evidence and correlation IDs;
- allocation run evidence and latest-run reconciliation;
- subscription-wide Claude CCU external rows.

The Workbook also contains pseudonymous subject IDs. Apply the same restricted
access and external alias rule.

## Data delay and freshness

The data sources refresh at different times:

| Source | Typical behavior |
| --- | --- |
| APIM metrics and usage events | Seconds to minutes |
| Application Insights and Log Analytics | Seconds to minutes |
| Foundry metrics | Minutes |
| Cost Management | Hours or longer |
| Managed FOCUS exports and FinOps processing | Delayed daily or monthly data |

`azd up` verifies the hub, exact export scope, formats, schedules, permissions,
and active configuration. It starts the managed exports. It cannot verify that
new billed rows are immediately available.

If a cost panel is empty, check freshness and export state first. Do not replace
an unavailable value with zero.

## Useful KQL

### Structured token attribution

```kusto
AIRequestUsage_CL
| where TimeGenerated > ago(24h)
| summarize
    Requests = count(),
    Tokens = sum(TotalTokens),
    Estimate = sum(EstimatedCost)
  by TeamId, SubjectId, Provider, ResponseModel, ProjectId
| order by Tokens desc
```

### Workload allocation reconciliation

```kusto
AICostAllocation_CL
| where SourceScope =~ "<exact-main-resource-group-id>"
| where IncludedInWorkloadTotal == true
| summarize
    SourceBilled = any(SourceBilledCost),
    AllocatedBilled = sum(AllocatedBilledCost),
    UnallocatedBilled = sum(UnallocatedBilledCost),
    SourceEffective = any(SourceEffectiveCost),
    AllocatedEffective = sum(AllocatedEffectiveCost),
    UnallocatedEffective = sum(UnallocatedEffectiveCost)
  by RunId, SourcePath, MeterId, ResourceId
| extend
    BilledResidual = SourceBilled - AllocatedBilled - UnallocatedBilled,
    EffectiveResidual = SourceEffective - AllocatedEffective - UnallocatedEffective
```

### Claude external context

```kusto
AICostAllocation_CL
| where SourceScope == "subscription"
| where AttributionStatus == "external-unallocated"
| where IncludedInWorkloadTotal == false
| where Provider =~ "Anthropic"
```

## Demo and production limits

- The design is single-region and uses public PaaS endpoints.
- The demo has no production identity alias directory.
- Subscription Claude context exposes an aggregate to restricted operators.
- Rate cards can become stale and never prove a private billing rate.
- Allocation supports showback evidence. Finance governance is still required
  for chargeback.
- Add workload objectives, tested alert routing, private-network assessment,
  finance controls, and formal evaluations before production use.

See [NOTICE.md](../NOTICE.md) for third-party notices and pinned source
attribution.

## References

- [FinOps hubs overview](https://learn.microsoft.com/cloud-computing/finops/toolkit/hubs/finops-hubs-overview)
- [FOCUS overview](https://learn.microsoft.com/cloud-computing/finops/focus/what-is-focus)
- [Cost Management exports](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-export-acm-data)
- [Azure Monitor Logs Ingestion API](https://learn.microsoft.com/azure/azure-monitor/logs/logs-ingestion-api-overview)
- [Event Hubs Capture](https://learn.microsoft.com/azure/event-hubs/event-hubs-capture-overview)
- [APIM LLM token metrics](https://learn.microsoft.com/azure/api-management/llm-emit-token-metric-policy)
- [Claude CCU billing](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/claude-models-billing)
