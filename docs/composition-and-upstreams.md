# Composition and upstreams

## Purpose

This document records how this demo is composed. It states which parts come from
upstream sources, why the project uses each part, and which upstream features the
project does not use. It grounds each claim in repository files, Git history, or a
permanent upstream citation.

The project is a demonstration and proof of concept. It is not a production
service. It optimizes for clear teaching of Microsoft tooling, Azure architecture,
and Microsoft AI patterns.

## How to read this document

- The [reuse classes](#reuse-classes) define the provenance labels.
- The [composition matrix](#composition-matrix) lists each component, its local
  path, its upstream, its reuse class, and its evidence.
- The [omitted upstream features](#omitted-upstream-features) section states what
  the project deliberately does not use, and why.
- The [decision rationale](#decision-rationale) section records the neutral,
  evidence-based reasons for the main choices.
- The [open questions](#open-questions) section states unresolved items and
  environment-specific confirmations.

## Authoritative sources

The original Microsoft repositories are authoritative reference implementations.
The project treats their published shapes as the reference. A deviation from an
upstream shape needs a documented reason or explicit approval.

The community inspiration and any repository-specific code are not Microsoft best
practice. This document does not label them as such.

## Reuse classes

| Class | Meaning |
| --- | --- |
| Exact vendored source | The upstream files are copied into the repository and pinned by commit and digest. They remain byte-identical. Any deployment-time compatibility correction is documented separately. |
| Pinned AVM module | An Azure Verified Module is referenced from the public Bicep registry at a fixed version. The registry supplies the module at build time. |
| Adapted sample | The project copies a Microsoft sample shape, then changes parameters or structure for this demo. |
| SDK or platform feature | The project uses a supported SDK, API, or platform policy as documented on Microsoft Learn. No upstream repository code is copied. |
| Published third-party package | The application consumes a package and its supported interfaces. These dependencies are not Microsoft reference implementations. |
| Original repository extension | The project adds code that has no direct upstream. The design follows documented Microsoft patterns. |
| Community inspiration | A community repository provided early inspiration. It is not an authoritative source and not a Microsoft reference implementation. This project does not claim verified file-level reuse of its content. |

## Composition matrix

Local paths are repository-relative. Permalinks pin a commit or release tag.

| Component | Local path | Upstream (version / permalink) | Reuse class | Rationale | Omitted upstream features | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| Microsoft FinOps hubs (FinOps toolkit) | `infra/vendor/finops-toolkit/v14/` | microsoft/finops-toolkit v14, commit [`f3b1b23`](https://github.com/microsoft/finops-toolkit/tree/f3b1b23f3ea6044bcd8cb767620cdd43704ce90a), asset `finops-hub-v14.zip` | Exact vendored source | Pin the exact FinOps source so the deployment does not fetch that mutable asset at deploy time. `azd`, AVM modules, language packages, and Azure still require network access. | Azure Data Explorer, Microsoft Fabric, Power BI, cost recommendations, and remote hub. See omitted features. | `infra/vendor/finops-toolkit/v14/RELEASE-MANIFEST.json`; `NOTICE.md`; digest `sha256:cd8cae56daa324552efad711ff0f23cdb1b671e9eae215b95861029311dc8ca2` |
| FinOps hub wrapper | `infra/modules/finops-hub-wrapper.bicep` | Wraps the vendored FinOps hub `main.bicep` | Original repository extension | Set the scoped, demo-safe parameters and call the pinned hub template. | Not applicable. | `infra/modules/finops-hub-wrapper.bicep` |
| FinOps release verification | `scripts/verify-finops-release.ps1` | Verifies the pinned asset digest | Original repository extension | Confirm the vendored release matches the pinned commit and digest before compilation and the documented UTC correction. | Not applicable. | `scripts/verify-finops-release.ps1`; `RELEASE-MANIFEST.json` |
| FinOps trigger script cache | `hooks/finops-script-cache.ps1` | Microsoft FinOps `Init-DataFactory.ps1` and [ARM script execution semantics](https://learn.microsoft.com/azure/azure-resource-manager/templates/deployment-script-template#run-script-more-than-once) | Original repository extension | Clear only successful, hub-owned execution records whose script matches the pinned Microsoft source. This makes the upstream stop/start logic run before and after each deployment pass. | No replacement trigger logic or changes to vendored source. | [Microsoft Data Factory deployment guidance](https://learn.microsoft.com/azure/data-factory/continuous-integration-delivery-sample-script) |
| FinOps UTC schedule correction | `hooks/finops-template.ps1` | [microsoft/finops-toolkit#2157](https://github.com/microsoft/finops-toolkit/issues/2157) and [Data Factory schedule rules](https://learn.microsoft.com/azure/data-factory/how-to-create-schedule-trigger) | Original repository compatibility correction | Add a conditional `Z` suffix to three compiled schedule definitions when the time zone resolves to UTC. Preserve mapped local-time schedules and all vendored files. | The deployed template has this explicit correction; it is not an unmodified upstream deployment artifact. | Guarded by the expected v14 schedule count, start values, and time-zone expressions. |
| FinOps export throttle retry | `hooks/finops-template.ps1` | FinOps toolkit v14 `Trigger export` Web Activity and [Data Factory Web Activity](https://learn.microsoft.com/azure/data-factory/control-flow-web-activity) | Original repository compatibility correction | Change the compiled activity from zero retries to three retries at 60-second intervals. This matches the observed Cost Management HTTP 429 retry period. Preserve all vendored files. | The deployed template has this explicit correction; it is not an unmodified upstream deployment artifact. | Guarded by the exact v14 activity name, type, timeout, retry count, and interval. |
| FinOps initial export configuration | `hooks/finops-foundation.ps1` | Microsoft FinOps `config_ConfigureExports` pipeline in `Microsoft.CostManagement/ManagedExports/app.bicep` | Original repository orchestration | Run the upstream pipeline after provisioning and wait for success. Do not rely on a settings event emitted before its trigger was active. Reuse the existing hub-owned identity on redeployment. | No custom export-creation pipeline. | `FINOPS_CONFIGURE_EXPORTS_RUN_ID` identifies the configuration run in Data Factory. |
| Export identity access | `infra/modules/finops-export-access.bicep` | [Microsoft Cost Management export identity requirements](https://learn.microsoft.com/azure/cost-management-billing/costs/tutorial-improved-exports#configure-exports-for-storage-accounts-with-a-firewall) | Original repository extension | Give the Data Factory identity `Role Based Access Control Administrator` on the FinOps storage account so Cost Management can grant export identities container access. | No access-administration role at resource-group or subscription scope. A separate provisioning identity is the stricter production alternative. | The FinOps wrapper owns the role assignment; deleting the support resource group removes it. |
| Event Hubs namespace | `infra/modules/usage-event-stream.bicep` | Azure/bicep-registry-modules AVM `avm/res/event-hub/namespace` [0.15.0](https://github.com/Azure/bicep-registry-modules/tree/avm/res/event-hub/namespace/0.15.0/avm/res/event-hub/namespace) | Pinned AVM module | Use a supported, versioned module for the Event Hubs namespace with Capture. | Module features not enabled for this demo, for example private endpoints. | `usage-event-stream.bicep` reference `br/public:avm/res/event-hub/namespace:0.15.0`; AVM tag SHA `4f750c70f333b2df6170e3b56ae90faa852361d2` |
| Claude on Foundry deployment shape | `infra/modules/foundry.bicep` | Azure-Samples/claude, [`infra-bicep/infra/foundry.bicep`](https://github.com/Azure-Samples/claude/blob/8b3ded4691e48b5c28d43dbbbee6cb4868936ff3/infra-bicep/infra/foundry.bicep) | Adapted sample | Follow the Microsoft-maintained Marketplace deployment shape for Claude Opus on Foundry. | The sample also ships Sonnet and Terraform variants. This demo deploys only Claude Opus with Bicep. | `foundry.bicep` comment and resource block (`format: 'Anthropic'`, `organizationName`, `countryCode`, `industry`, `deployments@2025-10-01-preview`) |
| APIM GenAI gateway policies | `apim-policies/*.xml` | Microsoft Learn GenAI gateway policies: [`llm-emit-token-metric`](https://learn.microsoft.com/azure/api-management/llm-emit-token-metric-policy), [`llm-content-safety`](https://learn.microsoft.com/azure/api-management/llm-content-safety-policy), [`log-to-eventhub`](https://learn.microsoft.com/azure/api-management/log-to-eventhub-policy) | SDK or platform feature | Use the documented API Management policies for token metrics, content safety, and Event Hubs logging. | Not applicable. | `apim-policies/README.md`; policy XML files |
| Azure Monitor dashboards with Grafana | `infra/dashboards/grafana-dashboard.json`; `infra/modules/grafana-dashboard.bicep` | Grafana Azure Monitor query schema and [built-in Key Vault dashboard at commit `e7cd4e6`](https://github.com/grafana/grafana/blob/e7cd4e6259fbd97b5288f40f70e36aefee6b01d9/public/app/plugins/datasource/azuremonitor/dashboards/keyvault.json) | Adapted sample | Use the upstream target layout, then constrain it for the Azure portal-hosted Grafana runtime. | The local metric target keeps `subscription` at target level and limits each `resources` entry to `resourceGroup` and `resourceName`. It also retains `metricDefinition` beside `metricNamespace`. See the compatibility deviation below. | `scripts/test-token-cost-attribution.ps1`; [compatibility fix `400cd7a`](https://github.com/gjlumsden/ai-observability-demo/commit/400cd7a); live Azure metric queries |
| Application telemetry | `src/web/` (`@azure/monitor-opentelemetry` 1.19.0) | [Azure Monitor OpenTelemetry Distro](https://learn.microsoft.com/azure/azure-monitor/app/opentelemetry-enable) | SDK or platform feature | Auto-instrument the web app for Application Insights. | Not applicable. | `src/web/package.json`; `src/web/README.md` |
| Web server, templates, and UI | `src/web/app.js`, `src/web/views/`, `src/web/scripts/copy-govuk-assets.js` | [Express](https://github.com/expressjs/express), [Nunjucks](https://github.com/mozilla/nunjucks), [GOV.UK Frontend](https://github.com/alphagov/govuk-frontend) | Published third-party package | Provide routing, server-rendered pages, and UI components without implementing those functions in this repository. GOV.UK assets are copied during the web build. | The project does not reproduce the GOV.UK service or claim a Microsoft UI reference implementation. | `src/web/package.json`; `src/web/package-lock.json`; upstream code and asset licences |
| Interactive sign-in | `src/web/` (Azure App Service Authentication / Easy Auth) | Azure App Service Authentication platform feature | SDK or platform feature | Validate the token signature, issuer, audience, and lifetime at the platform edge with `WEBSITE_AAD_ENABLE_MISE=true`. The app reads identity from `X-MS-CLIENT-PRINCIPAL-*` and `X-MS-TOKEN-AAD-*` headers. This is the Microsoft-approved MISE-compliant path for Node on App Service. | Application-managed MSAL library and Express session, removed. | `infra/modules/app-service.bicep`; `src/web/middleware/auth.js`; `src/web/README.md` |
| Usage processor | `src/usage-processor/` | Azure SDKs: `azure-eventhub`, `azure-monitor-ingestion`, `azure-monitor-query`, `azure-mgmt-costmanagement`, `azure-identity`, `azure-storage-blob`, `azure-data-tables`, `azure-functions` | Original repository extension | Read Event Hubs events and allocate FOCUS cost. Microsoft FinOps FOCUS normalizes the authoritative billing data and the Logs Ingestion API appends rows. Neither provides the pseudonymous team or user allocation or the atomic multi-batch publication. The processor adds those with a stable `RecordId`, a `run-complete` marker, and `ExpectedRecordCount`. | Not applicable. | `src/usage-processor/usage_processor/allocation.py`; `src/usage-processor/schemas/ai-cost-allocation.v1.json`; `src/usage-processor/requirements.txt` |
| Project inspiration | Overall project | lestermarch/core-ai-platform-demo, [commit `3724a54`](https://github.com/lestermarch/core-ai-platform-demo/tree/3724a540e22740006eddbff5055e52046a2b1719) | Community inspiration | A community repository provided early inspiration for a Foundry-centred `azd` and Bicep project. This project does not claim file-level reuse of its content without evidence. The Microsoft original repositories and platform features are the authoritative references. | The community repository uses AI Search and Cosmos DB agents. This project uses different scenarios. | `README.md` acknowledgements |

## FinOps export-throttle compatibility deviation

The pinned Microsoft FinOps toolkit v14 source remains authoritative and byte-identical.
Its `Trigger export` Data Factory Web Activity sets `retry` to `0` and
`retryIntervalInSeconds` to `30`.

The deployed Cost Management endpoint returned HTTP 429 on consecutive daily runs.
Its response required a 60-second retry delay. With zero retries, the upstream
`config_RunExportJobs` pipeline failed and no new FOCUS dataset reached the hub.

The repository changes only the compiled deployment template. It sets three bounded
retries with a 60-second interval. The timeout, request, identity, export scope, and
all other activity fields remain unchanged. The vendored release remains unchanged.
`scripts/test-lifecycle-hooks.ps1` stops if the expected upstream activity shape changes.

Remove this correction when a later authoritative FinOps release includes equivalent
Cost Management throttling protection and live scheduled runs succeed without it.

## Grafana metric-query compatibility deviation

The upstream Grafana Azure Monitor query model is authoritative. This repository
uses its target-level `subscription` field and its `resources` collection.

The Azure portal-hosted Grafana runtime did not accept every field allowed by the
newer upstream `AzureMonitorResource` type. When `subscription`, `region`, and
`metricNamespace` were also present inside a resource entry, the runtime built an
invalid Azure resource path. It treated the literal `resourceGroups` path segment
as a subscription identifier and returned `InvalidSubscriptionId`.

The repository therefore uses this constrained compatibility shape for Azure
Monitor metric targets:

```json
{
  "subscription": "<subscription-guid>",
  "azureMonitor": {
    "resources": [
      {
        "resourceGroup": "<resource-group>",
        "resourceName": "<resource-name>"
      }
    ],
    "metricDefinition": "<resource-type>",
    "metricNamespace": "<resource-type>"
  }
}
```

This is a deliberate compatibility deviation from the full generated resource
type. It does not change the metric name, aggregation, resource scope, or Azure
subscription. The constrained resource entry is the confirmed correction for the
observed error. The repository also retains `metricDefinition` beside
`metricNamespace` as a compatibility guard for portal-hosted Grafana versions.
That duplicate field was not identified as the direct cause of the error.

`scripts/test-token-cost-attribution.ps1` enforces the constrained shape. Direct
Azure Monitor queries verify all six metrics after deployment. Remove this
compatibility shape only after a live portal-hosted dashboard test proves that the
runtime accepts the newer upstream representation without `InvalidSubscriptionId`.

## Microsoft SDK and package sources

The project uses published Microsoft SDK and platform packages. It does not copy
source code from these repositories. The table lists the authoritative source
repositories for reference.

| Package | Local use | Authoritative source repository |
| --- | --- | --- |
| `@azure/monitor-opentelemetry` | `src/web/` telemetry | [Azure/azure-sdk-for-js](https://github.com/Azure/azure-sdk-for-js) |
| `azure-identity`, `azure-eventhub`, `azure-monitor-ingestion`, `azure-monitor-query`, `azure-mgmt-costmanagement`, `azure-storage-blob`, `azure-data-tables` | `src/usage-processor/` | [Azure/azure-sdk-for-python](https://github.com/Azure/azure-sdk-for-python) |
| `azure-functions` | `src/usage-processor/` runtime | [Azure/azure-functions-python-library](https://github.com/Azure/azure-functions-python-library) |
| Azure CLI 2.89.0 execution image | HMAC secret bootstrap in `infra/modules/identity-vault.bicep` | [Azure/azure-cli image definition](https://github.com/Azure/azure-cli/blob/azure-cli-2.89.0/azure-linux.dockerfile) |

Using a package as a dependency differs from copying sample code. This project
copies a sample shape only for the Claude deployment. See the
[composition matrix](#composition-matrix).

The HMAC bootstrap retains the Azure deployment-script service and managed identity.
Its execution image includes `jq`, which the service wrapper and bootstrap require.
Azure CLI 2.64.0 omitted that dependency; see
[Azure/azure-cli#29830](https://github.com/Azure/azure-cli/issues/29830).
The image pin does not constrain the operator's local Azure CLI.
When updating it, follow Microsoft's
[deployment-script image certification guidance](https://learn.microsoft.com/azure/azure-resource-manager/bicep/deployment-script-develop#syntax).
Do not select an image released within the previous 30 days.

The vendored FinOps files must remain byte-identical to the pinned archive.
`.gitattributes` disables Git text conversion for that directory. This prevents
Windows checkout settings from changing release hashes. Other source files retain
their existing line-ending conventions.

## Omitted upstream features

The project deliberately does not use the following upstream features. Each row
states the reason from the approved design.

| Upstream feature | Source | Reason to omit |
| --- | --- | --- |
| Azure Data Explorer analytics | FinOps hubs v14 | The demo scope needs FOCUS exports only. It sets `dataExplorerName=''`. |
| Microsoft Fabric query | FinOps hubs v14 | Out of demo scope. It sets `fabricQueryUri=''`. |
| Power BI reports | FinOps toolkit | The demo uses Grafana and one Workbook as the reporting surfaces. |
| Cost recommendations | FinOps hubs v14 | Out of demo scope. It sets `enableRecommendations=false`. |
| Remote hub storage | FinOps hubs v14 | The demo uses a single sibling support resource group. It sets `remoteHubStorageUri=''`. |
| Subscription, billing-account, or management-group export scope | FinOps hubs v14 | The design allows exactly one main resource-group scope. Wider scopes are rejected. |
| Claude Sonnet deployment and Terraform variant | Azure-Samples/claude | The demo deploys only Claude Opus with Bicep. |
| AI Search and Cosmos DB agent scenarios | lestermarch (community inspiration) | The community repository uses these scenarios. This project uses model comparison, code guardrail, and weather agent scenarios instead. |
| Full Azure Verified Modules landing zone | [AI Landing Zones](https://azure.github.io/AI-Landing-Zones/) | The demo uses direct Bicep resources to keep the cost-attribution story clear. It does not deploy the full landing zone module set. This repository does not assert conformance to the AI Landing Zones architecture. |

## Decision rationale

These records state the main choices in neutral, ADR style. Each choice comes
from the approved plan and prior analysis. The records do not attribute authorship
and do not cite private sessions.

### D1: One command deploys FinOps

- Decision: `azd up` deploys the application, the usage pipeline, FinOps hubs
  v14, and managed FOCUS exports. FinOps is mandatory, not optional.
- Reason: The demo must show attribution end to end from one repeatable command.

### D2: Managed FOCUS scope is one resource group

- Decision: The managed FOCUS export monitors exactly the main demo resource
  group. The deployment builds the scope internally and rejects wider scopes.
- Reason: A single, locked scope keeps the workload financial authority clear and
  avoids accidental subscription or billing exposure.

### D3: Subscription Claude CCU is external and unallocated

- Decision: The processor reads subscription-wide Claude Consumption Unit (CCU)
  actuals only as external context. It never allocates them to a team or
  individual and excludes them from every demo total.
- Reason: A subscription CCU total can include other workloads. Allocating it
  would create a false chargeback.

### D4: No optional FinOps analytics platform

- Decision: The deployment enables no Azure Data Explorer, Fabric, Power BI,
  recommendations, or remote hub.
- Reason: These add scope and cost without adding to the attribution story.

### D5: Premium storage for FinOps hub

- Decision: The FinOps hub storage uses `Premium_LRS`.
- Reason: The pinned hub design uses premium ADLS Gen2 storage for its ingestion
  path.

### D6: Public, managed-identity demo boundary

- Decision: The demo uses public PaaS endpoints and managed identities for
  service access. It uses no private network by default.
- Reason: The demo teaches attribution and governance. A production landing zone
  adds private networking as a later control.

### D7: Distinct provider estimate and allocated actual

- Decision: A versioned rate card produces a request estimate only. FOCUS
  `BilledCost` and `EffectiveCost` are the workload financial authority. An exact
  official `meterName`, `skuName`, or `armSkuName` identifies one model and token
  category. The processor weights a FOCUS cost only by that category's priced usage
  from the exact charged resource, the exact request model, and the matching
  rate-card version. Unknown meters, missing mappings, resource mismatches, and
  missing eligible usage stay unallocated. Not all cost is allocatable.
- Reason: Prevent confusion between a provider estimate and an allocated actual
  charge.

### D8: Vendor the pinned FinOps release

- Decision: Vendor the complete FinOps hubs v14 release, pinned by commit and
  digest. Do not fetch that mutable source asset during deployment.
- Reason: A pinned, vendored release makes the FinOps source fixed and verifiable.
  It does not remove the network dependency. `azd`, AVM modules, language
  packages, and the Azure control plane still need network access.

## Continuous integration

The build-only workflow `.github/workflows/ci.yml` validates the release
contracts. It does not deploy to Azure.

| Aspect | Value |
| --- | --- |
| Runner | Windows hosted runner (`windows-latest`) |
| Node.js | 24 |
| Python | 3.12 |
| Bicep CLI | 0.45.15, downloaded from the public upstream release and verified with its pinned SHA-256 |
| npm source | Microsoft npm proxy: `https://packagefeedproxy.microsoft.io/npm/` |
| pip source | Microsoft pip proxy: `https://packagefeedproxy.microsoft.io/pypi/simple` |
| GitHub Actions | Each action reference uses a pinned full commit SHA. |
| Repository permission | `contents: read` only. Checkout does not persist credentials. |
| Azure operations | No Azure sign-in, Azure credential, OIDC write permission, deployment, or Azure write. |
| Acceptance entry point | Existing release acceptance script: `scripts/test-token-cost-attribution.ps1` |

The workflow installs the pinned dependencies, verifies the Bicep CLI digest, and
runs the existing release acceptance script `scripts/test-token-cost-attribution.ps1`.
The script verifies the pinned FinOps artifact, the APIM policy contracts, the
lifecycle hooks, the HMAC and lifecycle Bicep modules, the dashboard and workbook
queries, the teardown contracts, the main and FinOps wrapper Bicep builds, the
Function contracts, the allocation contracts, all Python `unittest` tests, the Node
build, and the existing Node auth, security, usage, and weather tests.

### Validation limits

The workflow runs local and static checks only. It does not deploy. The state is in
repository, not deployed.

- Local and static coverage: checkpoint path, age, lag, statuses, safe trace fields,
  settings, and error propagation; the query contracts; JSON parsing; Bicep
  compilation; the warning baseline; PowerShell StrictMode tests; the Python tests;
  the Node tests; and `actionlint`.
- Deployed-environment confirmation only: live managed-identity access, Event Hubs
  partition reads, checkpoint blob reads and `LastModified` movement, `AppTraces`
  ingestion and cadence, alert behavior, and dashboard and workbook rendering.

## Interface status

This document reflects the settled code in the shared worktree. The web
authentication interface (Azure App Service Authentication / Easy Auth), the usage
processor allocation and publication contract, the checkpoint-monitoring and CI
interfaces, and the observability signal map are incorporated. The MISE
predeployment migration is complete. The postdeployment S360 compliance
confirmation is pending, as recorded in the open questions.

## Location and region

The docs do not name a fixed customer-facing Azure region. The deployment uses a
customer-selected location. Set the location with `azd env set AZURE_LOCATION
<azure-location>`. Confirm model access and quota in the selected location.

## Open questions

- MISE compliance: The web app uses Azure App Service Authentication (Easy Auth)
  with `WEBSITE_AAD_ENABLE_MISE=true`. This is the Microsoft-approved
  MISE-compliant path for Node and Express on App Service. The repository work is
  complete: the code migration from the MSAL
  library and Express session to Easy Auth, the `authsettingsV2` identity-provider
  configuration, and the auth tests. Platform settings (names only):
  `WEBSITE_AAD_ENABLE_MISE`, `MICROSOFT_PROVIDER_AUTHENTICATION_SECRET`,
  `ENTRA_CLIENT_ID`, `ENTRA_TENANT_ID`. Easy Auth activates when the postprovision
  hook populates the Entra client ID. Postdeployment confirmation is
  environment-specific: (1) deploy the pipeline; (2) check App Service
  `/.auth/version` for the MISE-enabled platform build; (3) confirm the S360
  MISE Compliance KPI. This repository and this document cannot establish the
  deployment or runtime-telemetry state. The authentication and
  dependency work is owned by the identity change set. Treat MISE compliance as
  confirmed only when the S360 KPI signal is compliant.

## References

- [Third-party notices](../NOTICE.md)
- [Feature catalog](features.md)
- [Architecture](architecture.md)
- [Observability and cost management](observability-and-cost-management.md)
- [FinOps hubs overview](https://learn.microsoft.com/cloud-computing/finops/toolkit/hubs/finops-hubs-overview)
- [FOCUS overview](https://learn.microsoft.com/cloud-computing/finops/focus/what-is-focus)
- [Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/)
- [AI Landing Zones](https://azure.github.io/AI-Landing-Zones/)
