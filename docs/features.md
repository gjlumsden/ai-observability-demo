# Feature catalog

## Purpose

This document lists the demo features. For each feature it states the business and
technical value, where to view it, the required permissions, the data authority
and delay, the demo boundary, and the current state.

The project is a demonstration and proof of concept. No environment is deployed by
reading this document. The state column describes what `azd up` provisions, not a
live environment.

## How to read this document

- Read the [state legend](#state-legend) first.
- Use the [feature summary](#feature-summary) to find a feature.
- Read the matching detail section for value, location, permissions, authority,
  delay, and boundary.

## State legend

| State | Meaning |
| --- | --- |
| In repository | The code exists in this repository. `azd up` provisions it. Nothing is deployed until you run the command. |
| External prerequisite | The feature needs an external approval, offer, or quota that this repository cannot grant. |
| Production hardening | The feature is not included. Add it before production use. |

## Feature summary

| Feature | Area | State |
| --- | --- | --- |
| [Governed AI gateway](#governed-ai-gateway) | Access | In repository |
| [Interactive Entra sign-in](#interactive-entra-sign-in) | Access | In repository; runtime MISE token and KPI evidence is environment-specific |
| [Team and synthetic-user attribution](#team-and-synthetic-user-attribution) | Attribution | In repository |
| [Bounded token metrics](#bounded-token-metrics) | Telemetry | In repository |
| [Structured usage events](#structured-usage-events) | Attribution | In repository |
| [HMAC pseudonymization](#hmac-pseudonymization) | Privacy | In repository |
| [Content safety and code guardrails](#content-safety-and-code-guardrails) | Safety | In repository |
| [Foundry weather agent with MCP tool](#foundry-weather-agent-with-mcp-tool) | Agents | In repository |
| [Resource-group FOCUS actuals](#resource-group-focus-actuals) | Cost | In repository |
| [Rate-card estimates](#rate-card-estimates) | Cost | In repository |
| [Cost allocation ledger](#cost-allocation-ledger) | Cost | In repository |
| [Atomic allocation publication](#atomic-allocation-publication) | Cost | In repository |
| [Subscription Claude CCU context](#subscription-claude-ccu-context) | Cost | In repository |
| [Grafana dashboards](#grafana-dashboards) | Reporting | In repository |
| [Investigation workbook](#investigation-workbook) | Reporting | In repository |
| [API Center inventory](#api-center-inventory) | Governance | In repository |
| [Budgets and alerts](#budgets-and-alerts) | Cost | In repository |
| [Usage processor pipeline](#usage-processor-pipeline) | Pipeline | In repository |
| [Checkpoint monitoring](#checkpoint-monitoring) | Pipeline | In repository; not deployed |
| [Event Hubs Capture archive and replay](#event-hubs-capture-archive-and-replay) | Pipeline | In repository |
| [Web journeys](#web-journeys) | Application | In repository |
| [Presenter guide](#presenter-guide) | Demo | In repository |
| [One-command lifecycle](#one-command-lifecycle) | Operations | In repository |

## Governed AI gateway

- Value (business): Route all model traffic through one governed gateway. Apply
  access, quota, and safety controls in one place.
- Value (technical): API Management validates user tokens, authenticates to
  Foundry with managed identity, routes GPT-5.4 and Claude Opus 5, and emits token
  telemetry.
- View (Azure): API Management resource. Native APIM Analytics for timeline, APIs,
  operations, products, subscriptions, and language models.
- View (local): `apim-policies/` policy files. See [`apim-policies/README.md`](../apim-policies/README.md).
- Permissions: Reader on the resource group to view. Contributor and role
  assignment rights to deploy.
- Data authority and delay: APIM metrics and events appear in seconds to minutes.
- Boundary: The demo uses a public APIM endpoint. Size the APIM tier and add
  network controls for the specific production workload. A higher tier is not
  universally required.
- State: In repository.

## Interactive Entra sign-in

- Value (business): Tie model use to a validated user identity.
- Value (technical): The web app uses Azure App Service Authentication (Easy Auth)
  with `WEBSITE_AAD_ENABLE_MISE=true`. The platform validates the token signature,
  issuer, audience, and lifetime at the platform edge before a request reaches the
  app. The app reads the identity from the `X-MS-CLIENT-PRINCIPAL-*` and
  `X-MS-TOKEN-AAD-*` headers. APIM validates the Entra audience and delegated scope
  before Foundry calls.
- Authentication approach: App Service Authentication replaces the previous MSAL
  library and Express session. This is the Microsoft-approved MISE-compliant path
  for Node and Express on App Service. The app
  runs no authentication library and manages no session, cookie, or client secret.
- Preserved behavior: interactive user sign-in through the reserved `/.auth/*`
  paths, the APIM access-token audience, the weather Model Context Protocol (MCP)
  machine-to-machine route protection, and the health endpoint. The design does
  not disable token validation.
- Predeployment (done): the code migration to Easy Auth, the `authsettingsV2`
  identity-provider configuration, `returnTo` redirect sanitization, and the
  trust-boundary tests. Platform settings (names only, values deployment-specific):
  `WEBSITE_AAD_ENABLE_MISE=true`, `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET`,
  `ENTRA_CLIENT_ID`, `ENTRA_TENANT_ID`. Easy Auth activates when the postprovision
  hook populates the Entra client ID.
- Test boundary: the predeployment tests (`npm run test:auth-validation`,
  `npm run test:auth-logging`) exercise this app's responsibility only. They deny a
  request with no forwarded identity header, accept a request that carries one, and
  sanitize the post-login redirect target. They do not verify token signature,
  issuer, audience, or lifetime. The platform validates those.
- Postdeployment: four steps confirm compliance in a deployed environment.
  (1) Deploy the pipeline. (2) Run the separate token-acceptance harness,
  `npm run postdeploy:auth-acceptance`, against the deployed instance. (3) Check App
  Service `/.auth/version` to confirm the MISE-enabled platform build. (4) Confirm
  the S360 MISE Compliance KPI becomes compliant. The repository contains the code
  and configuration for these steps. The deployment and acceptance state is
  environment-specific and is not established by this repository or this document.
- Token-acceptance harness: the postdeployment harness tests valid, expired,
  wrong-audience, wrong-issuer, and invalid-signature access tokens against a
  deployed instance. It requires `EASYAUTH_ACCEPTANCE_BASE_URL` (an `https` origin
  with no credentials, query, or fragment) and all five `EASYAUTH_ACCEPTANCE_*_TOKEN`
  fixtures before any network call. A missing base URL, an invalid base URL, or any
  missing fixture returns NOT RUN with exit code 2, never a pass. It sends each token
  only to the same origin, treats only `401` or `403` as a rejection, and never
  prints a token value or fragment.
- View (UI): The web app sign-in flow. See [`src/web/README.md`](../src/web/README.md).
- View (Azure): App Service Authentication settings. The Entra app registration
  created by the provisioning hook.
- Permissions: Rights to create and configure an Entra application and App Service
  Authentication.
- Data authority and delay: Sign-in is immediate. MISE KPI confirmation follows
  postdeployment telemetry.
- Boundary: The demo uses a public web endpoint. There is no local authentication
  bypass. The sign-in route sanitizes the `returnTo` target and falls back to a
  default path for an unsafe value.
- State: In repository. The predeployment migration is complete. The MISE platform
  version and S360 KPI confirmation are postdeployment and pending until the
  pipeline is deployed. They are not finished compliance.

## Team and synthetic-user attribution

- Value (business): Attribute token use to a team and a stable subject without
  storing personal identity.
- Value (technical): APIM assigns a `Team` dimension and an HMAC subject ID.
  Synthetic APIM users populate native Analytics user dimensions.
- View (Azure): APIM Analytics user and product views. Grafana attribution panels.
- View (local): `apim-policies/README.md`.
- Permissions: Reader on the resource group. Restricted access for subject-level
  panels.
- Data authority and delay: Provider responses are the token source. Metrics and
  events appear in seconds to minutes.
- Boundary: Subject IDs are pseudonyms. This repository stores no friendly alias
  map. Keep any name mapping in an external, access-controlled system.
- State: In repository.

## Bounded token metrics

- Value (business): Provide fast operational charts for token use, latency, and
  quota.
- Value (technical): APIM emits token metrics with exactly five dimensions: `API
  ID`, `Subscription ID`, `Team`, `Model`, and `Attribution Mode`.
- View (Azure): Application Insights custom metrics. Grafana operational panels.
- View (local): `apim-policies/README.md`.
- Permissions: Reader on the resource group.
- Data authority and delay: Seconds to minutes.
- Boundary: Metrics are bounded and low cardinality. They do not contain `User`,
  `Project`, `Operation ID`, or `Product ID`. Use structured events for those.
- State: In repository.

## Structured usage events

- Value (business): Keep a detailed request ledger for individual, project, and
  token analysis.
- Value (technical): APIM sends one pseudonymous JSON event per usable provider
  response to Event Hubs, and a usage-free failure event for gateway errors. The
  processor writes `AIRequestUsage_CL`.
- View (Azure): Log Analytics table `AIRequestUsage_CL`. The investigation
  workbook.
- View (local): Schema in `docs/observability-and-cost-management.md` and
  `src/usage-processor/schemas/`.
- Permissions: Log Analytics read access. Restricted access for subject panels.
- Data authority and delay: Provider responses are the token source. Events appear
  after processing, typically minutes.
- Boundary: Events exclude prompts, completions, raw object IDs, email addresses,
  access tokens, subscription keys, and IP addresses.
- State: In repository.

## HMAC pseudonymization

- Value (business): Protect personal identity while keeping stable attribution.
- Value (technical): APIM applies HMAC-SHA256 to tenant ID, subject kind, and
  validated subject before the event leaves the gateway.
- View (local): Privacy boundary in `apim-policies/README.md` and
  `docs/observability-and-cost-management.md`.
- Permissions: The HMAC key is a versionless Key Vault secret. The usage Function
  has no Key Vault secret role and cannot read it.
- Data authority and delay: Applied at request time.
- Boundary: The pseudonym is stable but not reversible by this demo.
- State: In repository.

## Content safety and code guardrails

- Value (business): Show layered safety for input and generated code.
- Value (technical): The layers are Prompt Shields, Azure AI Content Safety in
  APIM, the `rai-ai-observability-demo` policy on GPT-5.4, and Protected Material
  for Code.
- View (UI): The web app Prompt Shield and generated-code samples. Foundry
  **Guardrails + controls**.
- View (local): [`docs/guardrails.md`](guardrails.md).
- Permissions: Reader on Foundry and the resource group.
- Data authority and delay: Applied at request time. Telemetry appears in seconds
  to minutes.
- Boundary: The protected-code index is current only through April 6, 2023. A
  clear result is not legal approval. A block is not proof of infringement.
- State: In repository.

## Foundry weather agent with MCP tool

- Value (business): Show a governed agent that calls one authenticated, read-only
  tool.
- Value (technical): A Foundry v1 agent uses GPT-5.4 with low reasoning. APIM
  exposes one read-only weather operation as the `get_weather_forecast` MCP tool.
- View (UI): `weather-forecast-agent` in the Foundry agents view.
- View (local): [`agents/README.md`](../agents/README.md);
  `agents/weather-forecast/agent.json`.
- Permissions: Foundry data-plane access to create or update the agent. An APIM
  subscription key stored in the Foundry connection.
- Data authority and delay: The tool uses public demo data. It is not an official
  forecast source.
- Boundary: The tool is read-only and idempotent. It needs no tool approval.
- State: In repository.

## Resource-group FOCUS actuals

- Value (business): Provide authoritative billed cost for the locked workload
  scope.
- Value (technical): Microsoft FinOps hubs v14 run managed FOCUS exports for
  exactly the main demo resource group. FOCUS `BilledCost` and `EffectiveCost` are
  the workload financial authority.
- View (Azure): FinOps hub storage in the sibling support resource group. Grafana
  cost panels.
- View (local): `docs/observability-and-cost-management.md`;
  `infra/modules/finops-hub-wrapper.bicep`.
- Permissions: Elevated rights to deploy FinOps hubs and to assign `Cost
  Management Contributor` on the main resource group. Cost Management data access
  to read.
- Data authority and delay: Cost Management data is delayed by hours or longer.
  Managed exports run daily and monthly.
- Boundary: The export monitors only the main resource group. If a cost panel is
  empty, check freshness and export state. Do not replace an unavailable value
  with zero.
- State: In repository.

## Rate-card estimates

- Value (business): Estimate request cost by token type for a quick view.
- Value (technical): A versioned rate card normalizes provider tokens into an
  estimate. Each token category uses its pinned list rate. The estimate is an
  allocation weight, not an invoice value.
- View (Azure): `AIRequestUsage_CL` `EstimatedCost`. Grafana estimate panels.
- View (local): `src/usage-processor/usage_processor/rates.py`;
  `src/usage-processor/config/`.
- Permissions: Log Analytics read access.
- Data authority and delay: The rate card produces an estimate at processing time.
- Boundary: A rate card can become stale. It never proves a private billing rate.
- State: In repository.

## Cost allocation ledger

- Value (business): Show a defensible showback of workload cost by team.
- Value (technical): Microsoft FinOps FOCUS is the upstream billing primitive.
  Team and user allocation is custom application behavior. An OpenAI FOCUS row
  allocates only when the publisher or service and an exact official Azure Retail
  Prices `meterName`, `skuName`, or `armSkuName` identify one model and one token
  category. The denominator uses only usage from the exact charged
  `ModelResourceId`, the exact `RequestModel`, a matching `RateCardVersionId`, and
  the matching token category. Each category token count is multiplied by its
  pinned list rate, so `gpt-5.4`, `gpt-5.4-mini`, and `gpt-5.4-nano` never
  subsidize each other. A Claude Consumption Unit (CCU) row allocates only for the
  exact Anthropic CCU meter, the exact allowlisted resource, the configured Claude
  model, and the matching rate-card version. Unknown meters, missing mappings,
  resource mismatches, or missing eligible usage remain explicit unallocated rows.
  Not all cost is allocatable. Correction runs are append-only with source path and
  ETag.
- View (Azure): Log Analytics table `AICostAllocation_CL`. Grafana reconciliation
  panels. The investigation workbook.
- View (local): `src/usage-processor/usage_processor/allocation.py` and
  `allocation_service.py`.
- Permissions: Log Analytics read access.
- Data authority and delay: Follows FOCUS export delay.
- Boundary: Allocation supports showback evidence. Finance governance is still
  required for chargeback.
- State: In repository.

## Atomic allocation publication

- Value (business): Trust that a cost view reflects a complete run, not a partial
  write.
- Value (technical): Microsoft FinOps FOCUS normalizes the authoritative billing
  data. The Azure Monitor Logs Ingestion API appends telemetry rows. Neither
  provides pseudonymous team or user allocation, and neither confirms that a full
  multi-batch run landed. The processor adds a publication layer:
  - Stable `RecordId`: a SHA-256 hex digest of fixed identity fields (`RunId`, the
    source and meter keys, `TeamId`, `SubjectId`, `AllocationBasis`,
    `AttributionStatus`, `RateCardVersionId`, `RecordType`, `ExpectedRecordCount`).
    The same logical record always produces the same `RecordId`. A re-run appends
    idempotent rows that a query deduplicates.
  - `run-complete` marker: one row per run with `RecordType='run-complete'` and
    `AttributionStatus='run-complete'`. The processor emits it only after all
    ingestion batches succeed. It carries `ExpectedRecordCount`, the number of
    allocation rows the run produced.
  - Completeness check: a consumer deduplicates rows with
    `summarize arg_max(TimeGenerated, *) by RunId, RecordId`, then counts the
    allocation rows per `RunId` with exact `count()`. A run is complete only when the
    `run-complete` marker exists for the `RunId` and that count equals the latest
    marker's `ExpectedRecordCount`. A partial or duplicated append is detectable.
  - Per-attempt `RunId`: each processing attempt derives a deterministic `RunId`
    from the source type, path, ETag, and attempt number. A retried attempt is
    distinct and repeatable.
  - Selection: the query deduplicates by `RunId` and `RecordId`, uses exact
    `count()` per `RunId`, requires equality with the latest marker's
    `ExpectedRecordCount`, excludes the marker rows from cost totals, and selects the
    latest complete run per source identity. A partial attempt is never selected.
- View (Azure): `AICostAllocation_CL` rows. Filter `RecordType == 'run-complete'`
  for the markers.
- View (local): `src/usage-processor/usage_processor/allocation.py`
  (`build_run_complete_row`, `with_record_identity`);
  `src/usage-processor/schemas/ai-cost-allocation.v1.json`.
- Permissions: Log Analytics read access to query. The processor identity holds
  Monitoring Metrics Publisher on the data collection rule to write.
- Data authority and delay: FOCUS billing is the financial authority and follows
  the export delay. The Logs Ingestion append is near real time after a run.
- Boundary: FOCUS normalization and the Logs Ingestion append are platform
  features. The stable `RecordId`, the `run-complete` marker, and
  `ExpectedRecordCount` are original repository code with no direct upstream.
- State: In repository.

## Subscription Claude CCU context

- Value (business): Give operators a subscription-wide Claude cost reference.
- Value (technical): A subscription Cost Management query records Anthropic Claude
  CCU meters as external, unallocated rows with `IncludedInWorkloadTotal=false`.
- View (Azure): `AICostAllocation_CL` rows with `SourceScope='subscription'` and
  `AttributionStatus='external-unallocated'`. Restricted workbook panel.
- View (local): `src/usage-processor/usage_processor/cost_context.py`.
- Permissions: `Cost Management Reader` at subscription scope for the processor
  identity. Restricted operator access to view.
- Data authority and delay: Cost Management delay of hours or longer.
- Boundary: The value can include other workloads. It is excluded from every demo
  total and is never allocated.
- State: In repository.

## Grafana dashboards

- Value (business): Provide one decision view and one operator view.
- Value (technical): **AI Usage and Cost Attribution** is the decision dashboard.
  **Attribution Pipeline Operations** is the operator dashboard.
- View (Azure): Azure Monitor dashboards with Grafana. Resources
  `AI-Observability-and-Cost` and `Attribution-Pipeline-Ops`.
- View (local): `infra/dashboards/`; `infra/modules/grafana-dashboard.bicep`.
- Permissions: Grafana viewer access. Restricted access for subject panels.
- Data authority and delay: Follows the source signal delays.
- Boundary: Subject panels need restricted access. Subject IDs are pseudonyms.
- State: In repository.

## Investigation workbook

- Value (business): Provide filtered drill-down for evidence and reconciliation.
- Value (technical): The **AI Usage and Cost Investigation** workbook shows request
  and allocation ledgers, exceptions, evidence, reconciliation, and external
  context.
- View (Azure): Azure Monitor workbook.
- View (local): `infra/workbooks/monitoring-workbook.json`.
- Permissions: Workbook read access. Restricted access for subject panels.
- Data authority and delay: Follows the source signal delays.
- Boundary: The workbook contains pseudonymous subject IDs. Apply restricted
  access.
- State: In repository.

## API Center inventory

- Value (business): Record the governed APIs in one inventory.
- Value (technical): API Center records the governed OpenAI, Claude, and direct
  protected-code APIs.
- View (Azure): API Center resource.
- View (local): `infra/modules/api-center.bicep`.
- Permissions: Reader on the resource group.
- Data authority and delay: Updated at deploy time.
- Boundary: The inventory records the demo APIs only.
- State: In repository.

## Budgets and alerts

- Value (business): Give an early spend signal for both resource groups.
- Value (technical): The main resource group and the FinOps support resource group
  each have a budget and notifications. Export failure monitoring is included.
- View (Azure): Cost Management budgets. Alert rules.
- View (local): `infra/modules/cost-management.bicep`; `infra/modules/usage-alerts.bicep`.
- Permissions: Rights to create budgets and alerts.
- Data authority and delay: Budget evaluation follows Cost Management data delay.
- Boundary: A budget alerts. It does not stop model calls.
- State: In repository.

## Usage processor pipeline

- Value (business): Turn raw usage events into attributed usage and cost rows.
- Value (technical): A Python Flex Consumption Function uses managed identity. An
  Event Hub trigger writes `AIRequestUsage_CL`. Timers allocate FOCUS cost and
  record Claude CCU context. The Function writes through a direct data collection
  rule (DCR).
- View (Azure): Function App. Log Analytics tables. Operator dashboard.
- View (local): `src/usage-processor/`; `infra/modules/usage-processor.bicep`.
- Permissions: Managed identity roles for Event Hubs, storage, DCR ingestion, and
  Cost Management read. No Key Vault secret role.
- Data authority and delay: Usage rows appear in minutes. Cost rows follow export
  delay.
- Boundary: The processor accepts usage only from the exact deployed APIM and
  Foundry resource IDs. Other scopes are rejected.
- State: In repository.

## Checkpoint monitoring

- Value (business): Detect a stalled or missing usage-processing checkpoint before
  a data gap grows.
- Value (technical): A timer runs every five minutes (`0 */5 * * * *`) and emits
  one bounded Application Insights trace per Event Hubs partition per cycle. The
  `AppTraces` `Message` uses
  the fixed prefix `UsageProcessorCheckpointStatus `, which ends with one space.
  Compact, bounded JSON follows the prefix. The transport uses the message text,
  not `customDimensions`.
- Telemetry contract: the JSON uses these fixed keys.

  | Key | Meaning |
  | --- | --- |
  | `eventHubName` | Monitored Event Hub name |
  | `consumerGroup` | Processor consumer group |
  | `partitionId` | Event Hubs partition |
  | `status` | One of the status values below |
  | `checkpointAgeSeconds` | Age of the stored checkpoint |
  | `eventAgeSeconds` | Age of the last enqueued event |
  | `checkpointSequenceNumber` | Last checkpointed sequence number |
  | `lastEnqueuedSequenceNumber` | Last enqueued sequence number |
  | `sequenceLag` | Difference between enqueued and checkpointed sequence numbers |
  | `checkpointLastModifiedUtc` | Checkpoint last-modified time |
  | `lastEnqueuedTimeUtc` | Last enqueued event time |
  | `staleThresholdSeconds` | Configured stale threshold |
  | `idleThresholdSeconds` | Configured idle threshold |

- Statuses: `healthy`, `lagging`, `idle`, `stale`, `missing`, and `invalid`.
- Status rules (thresholds are in seconds):
  - `healthy`: the checkpoint is caught up and the last event is newer than
    `CHECKPOINT_IDLE_SECONDS`.
  - `idle`: the partition is empty; or the checkpoint is caught up and the last
    event age is at least `CHECKPOINT_IDLE_SECONDS`.
  - `lagging`: the checkpoint has a positive sequence lag and its age is below
    `CHECKPOINT_STALE_SECONDS`. There is no separate lag threshold.
  - `stale`: the checkpoint is behind the partition tail and its age is at least
    `CHECKPOINT_STALE_SECONDS`.
  - `missing`: the partition is nonempty and the expected checkpoint blob does not
    exist.
  - `invalid`: the checkpoint has no valid `sequencenumber` metadata, or its
    sequence number is ahead of the current partition tail.

  The monitor reads the checkpoint before the Event Hubs partition properties. This
  order prevents a normal concurrent checkpoint advance from being classified as
  `invalid`.
- Alerting: alert only on `stale`, `missing`, and `invalid`. The `healthy`,
  `lagging`, and `idle` states are informational and are not alerted. An alert
  requires two consecutive failing 15-minute evaluations over a 30-minute window.
  This suppresses transient startup conditions.
- Checkpoint basis: the checkpoint data derives from the Azure Functions Event
  Hubs trigger checkpoint store in blob storage. The store uses the container
  `azure-webjobs-eventhub`. Each checkpoint uses the lowercase blob name
  `{fully-qualified-namespace}/{event-hub}/{consumer-group}/checkpoint/{partition-id}`.
  The blob metadata keys are `offset`, `sequencenumber`, and `clientidentifier`.
  The checkpoint age uses the blob `LastModified` time. The store layout comes from
  the Microsoft Azure SDK for .NET:
  [`BlobCheckpointStoreInternal.cs`](https://github.com/Azure/azure-sdk-for-net/blob/f0426886a3e8417dd597429e7a91f21999bdae9c/sdk/eventhub/Azure.Messaging.EventHubs.Shared/src/BlobCheckpointStore/BlobCheckpointStoreInternal.cs),
  [`BlobMetadataKey.cs`](https://github.com/Azure/azure-sdk-for-net/blob/f0426886a3e8417dd597429e7a91f21999bdae9c/sdk/eventhub/Azure.Messaging.EventHubs.Shared/src/BlobCheckpointStore/BlobMetadataKey.cs),
  and
  [`EventHubOptions.cs`](https://github.com/Azure/azure-sdk-for-net/blob/f0426886a3e8417dd597429e7a91f21999bdae9c/sdk/eventhub/Microsoft.Azure.WebJobs.Extensions.EventHubs/src/Config/EventHubOptions.cs).
- Required settings (names only): `USAGE_STORAGE_BLOB_ENDPOINT`,
  `AIUsageEventHub__fullyQualifiedNamespace`, `AI_USAGE_EVENT_HUB_NAME`,
  `AI_USAGE_CONSUMER_GROUP`, `CHECKPOINT_STALE_SECONDS`, and
  `CHECKPOINT_IDLE_SECONDS`. The user-assigned identity selection uses the existing
  `AIUsageEventHub__clientId` and `AzureWebJobsStorage__clientId` settings.
- Thresholds: the app settings `CHECKPOINT_STALE_SECONDS` and
  `CHECKPOINT_IDLE_SECONDS` are each a positive integer number of seconds. The
  default for both is `900`, set in `infra/modules/usage-processor.bicep`. They
  surface in the telemetry as `staleThresholdSeconds` and `idleThresholdSeconds`.
- View (Azure): `AppTraces` filtered by the message prefix. The Attribution
  Pipeline Operations dashboard.

  ```kusto
  AppTraces
  | where Message startswith "UsageProcessorCheckpointStatus "
  | extend Status = parse_json(substring(Message, strlen("UsageProcessorCheckpointStatus ")))
  | where tostring(Status.status) in ("stale", "missing", "invalid")
  ```

- View (local): The checkpoint module and `function_app.py` are owned by the
  operations change set.
- Permissions: Log Analytics read access to `AppTraces`. The processor reads the
  checkpoint store and Event Hubs metadata with its existing Storage Blob Data
  Owner and Azure Event Hubs Data Receiver roles.
- Data authority and delay: The processor emits the status on its monitoring
  cadence. Application Insights ingestion adds seconds to minutes.
- Reliability: `host.json` enables Application Insights sampling but excludes the
  `Request` and `Trace` types (`excludedTypes: "Request;Trace"`). This keeps the
  low-volume periodic checkpoint trace from being sampled away. Production
  trade-off: this retains all Function traces. To reduce trace volume later, route
  the checkpoint signal to a dedicated, unsampled telemetry type.
- Sampling: `src/usage-processor/host.json` excludes the `Trace` telemetry type
  from Application Insights sampling. Sampling therefore keeps each periodic
  partition status available to the alert query.
- Boundary and privacy: The trace has no event body, user identifier, prompt, or
  completion. It contains only the bounded status fields above.
- State: In repository, not deployed. Deployment confirms the live threshold
  values, the role assignments, access to checkpoint blobs and Event Hubs partition
  properties, `AppTraces` ingestion at the unsampled cadence, and alert firing and
  resolution. Do not claim live verification before deployment.

## Event Hubs Capture archive and replay

- Value (business): Keep durable evidence and allow recovery after a failure.
- Value (technical): Event Hubs Standard uses Capture to write a pseudonymous
  archive. The processor can replay Capture records after a DCR ingestion failure.
- View (Azure): Event Hubs namespace. Usage storage archive container.
- View (local): `infra/modules/usage-event-stream.bicep`; `usage-storage.bicep`.
- Permissions: Storage and Event Hubs data roles for the processor identity.
- Data authority and delay: Live events retain for seven days. The archive retains
  for 400 days.
- Boundary: The archive holds pseudonymous events only.
- State: In repository.

## Web journeys

- Value (business): Provide repeatable demo journeys for model comparison and code
  guardrails.
- Value (technical): An Express and Nunjucks app styled with GOV.UK Frontend v5
  provides Governed Model Comparison and Scientific Code Explainer. The app shows
  provider token totals. It does not calculate billed cost.
- View (local): Run the app.

  ```powershell
  cd src\web
  npm install
  npm run dev
  ```

- View (UI): The web app in a browser at the configured port.
- Permissions: Interactive Entra sign-in for the deployed app.
- Data authority and delay: Provider responses are the token source. The app shows
  returned totals immediately.
- Boundary: Do not enter proprietary code, secrets, or personal data.
- State: In repository.

## Presenter guide

- Value (business): Support a short, repeatable presentation.
- Value (technical): A static single-page guide and a configured presenter launcher
  provide the demo sequence.
- View (local): Open `demo-scripts/presenter.html` for the static guide. Open the
  configured presenter after deployment:

  ```powershell
  pwsh ./demo-scripts/open-presenter.ps1 -Slide 1 -Range 24h
  ```

- View (local): [`demo-scripts/run-demo.md`](../demo-scripts/run-demo.md).
- Permissions: None for the static guide. Deployment configuration for the
  launcher.
- Data authority and delay: The guide is static.
- Boundary: Deployment-only buttons stay hidden until the launcher has valid
  configuration.
- State: In repository.

## One-command lifecycle

- Value (business): Deploy and remove the demo with one command each.
- Value (technical): `azd up` provisions the application, the usage pipeline,
  FinOps hubs v14, and managed FOCUS exports. `azd down --force --purge` removes
  both active resource groups and external role assignments.
- View (CLI):

  ```powershell
  azd env set AZURE_LOCATION <azure-location>
  azd up
  ```

  Run the complete cleanup:

  ```powershell
  pwsh ./demo-scripts/teardown.ps1
  ```

- View (local): [`docs/RUNBOOK.md`](RUNBOOK.md).
- Permissions: Rights to create two resource groups, the documented resources,
  subscription-level role assignments, budgets, and managed exports.
- External prerequisites: An Azure subscription. Foundry model access and quota in
  the selected location. Azure Marketplace permission and quota for the Claude
  Opus offer.
- Data authority and delay: Provisioning takes time. Cost data appears after Cost
  Management completes an export.
- Boundary: Key Vault purge protection keeps deleted vault data recoverable for its
  Azure retention period. The Claude Marketplace subscription remains outside the
  resource groups and requires a separate review.
- State: In repository. Model access, quota, and the Marketplace offer are external
  prerequisites.

## Production hardening not included

Add the following before production use. These items are not in this demo.

- Private networking, virtual network, and private endpoints.
- Tested alert routing and service-level objectives.
- A production identity alias directory.
- Formal finance governance for chargeback.
- Formal model evaluations.

## References

- [Composition and upstreams](composition-and-upstreams.md)
- [Architecture](architecture.md)
- [Observability and cost management](observability-and-cost-management.md)
- [Guardrails](guardrails.md)
- [Runbook](RUNBOOK.md)
