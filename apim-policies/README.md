# APIM policy set

These policies configure Azure API Management Basic v2 as the demo AI Gateway.

Azure Monitor captures gateway records and LLM token metadata at 100%. Prompt and completion message logging stays disabled.

## Model APIs

- `openai-model.xml` routes the OpenAI Responses API to GPT-5.4.
- `claude-model.xml` routes the Anthropic Messages API to Claude Opus 5.
- `protected-code.xml` routes direct code checks to Protected Material for Code.
- Both APIs use APIM managed identity for backend authentication.
- The Presenter, Research and Engineering products provide separate subscription keys for attribution.

## Live policies

- `validate-azure-ad-token` checks the Entra audience and delegated scope before Foundry calls.
- `llm-content-safety` enables prompt shield and completion safety using Azure AI Content Safety.
- `authentication-managed-identity` authenticates APIM to Foundry with the APIM system-assigned identity.
- `llm-emit-token-metric` emits token metrics with exactly five configured dimensions: API ID, Subscription ID, Team, Model, and Attribution Mode.
- CORS, correlation ID handling and header cleanup are applied globally.

APIM sends gateway logs to Log Analytics and requests, dependencies, exceptions, and custom token metrics to Application Insights.

## Telemetry destinations

| Destination | Configuration | Data |
| --- | --- | --- |
| Application Insights | `applicationinsights` APIM diagnostic, 100% sampling | Requests, dependencies, exceptions, correlation, and custom token metrics |
| Event Hubs | Buffered `usage-event-hub` APIM logger | Pseudonymous provider usage events for durable processing and replay |
| Log Analytics | `GatewayLogs` | Request, API, operation, product, subscription, user-owner, response, latency, and region metadata |
| Log Analytics | `GatewayLlmLogs` | Model, deployment, API version, request, and token metadata |
| Log Analytics | `AllMetrics` | APIM platform metrics in `AzureMetrics` |
| Native APIM Analytics | Gateway and LLM resource logs | Timeline, geography, APIs, operations, products, subscriptions, users, requests, and language models |

The LLM diagnostic sets `largeLanguageModel.logs` to `enabled`. It does not set request or response message logging.

`RequestMessages` and `ResponseMessages` remain empty. Query parameters are hidden in the Azure Monitor diagnostic.

The Presenter, Research, and Engineering APIM users are synthetic subscription owners. They populate native Analytics user dimensions without changing Entra authentication.

Native APIM metrics remain available in Azure Monitor Metrics independently of the resource diagnostic.

## Usage events

The three model policies send one JSON usage event through `log-to-eventhub` after a provider response. They use `preserveContent: true`, so clients receive the original response body unchanged. The policies also send a usage-free failure event for gateway errors after subject attribution completes.

The policies are self-contained because the APIM module does not deploy policy fragments. The module exports `usageEventHubLoggerId`, `usageEventHubLoggerName`, and `usageHmacNamedValueId`.

Event Hubs logging is independent of Application Insights sampling. Events stay bounded because the policy serializes fixed metadata and known numeric usage fields only.

APIM creates the pseudonym before the event leaves the gateway. The HMAC key is
a versionless Key Vault secret referenced by the secret APIM named value. A
temporary deployment identity creates or reuses the secret. The usage Function
has no Key Vault secret role and cannot read the HMAC key.

Each event contains:

- `schemaVersion`, `eventTimeUtc`, deterministic `eventId`, `correlationId`, and a validated W3C `traceId` when available.
- `provider`, `requestModel`, `responseModel`, `deploymentName`, `deploymentType`, `modelResourceId`, and `resourceGroupId`.
- `teamId`, HMAC-derived `subjectId`, `projectId`, and `attributionMode`.
- `requestOutcome`, `httpStatusCode`, `latencyMs`, and `tokenQuality`.
- Provider-specific numeric `rawUsage` and safely derived token totals.

GPT Responses events normalize inclusive input and output tokens, cached and uncached input, reasoning and visible output, and total tokens. GPT Chat Completions events apply the equivalent normalization to prompt and completion fields. Claude events add base input, cache reads, cache creation, optional 5-minute and 1-hour cache writes, inclusive input, output, optional thinking, and derived totals. Claude normalization uses the aggregate cache-creation count when present. It uses child cache counts only when the aggregate is absent.

Successful responses without a usable usage object have `tokenQuality` set to `missing`. A successful response without a usable JSON body has `requestOutcome` set to `unavailable`. Non-success responses have `requestOutcome` set to `failed`. These events do not claim token usage unless the provider supplies it.

## Privacy boundary

APIM creates `subjectId` before the event leaves the gateway. It applies HMAC-SHA256 with `{{usage-hmac-key}}` to `tenant ID|subject kind|validated subject`, then uses unpadded base64url encoding. Entra subjects use validated `tid` and `oid` claims. Synthetic users use allow-listed user IDs. The weather model uses the fixed `weather-forecast-agent` subject.

Events never include prompts, completions, access tokens, subscription keys, raw
Entra object IDs, email addresses, IP addresses, or request and response bodies.
`rawUsage` contains only known numeric provider usage fields. Provider response
IDs are inputs to the SHA-256 event ID and are not emitted.

Metrics and structured events have different purposes. Metrics use exactly API
ID, Subscription ID, Team, Model, and Attribution Mode. Individual, project,
operation, correlation, trace, and complete provider token categories come from
the structured events in `AIRequestUsage_CL`.

The resource group ID comes from the APIM deployment service ID. The model resource ID combines that resource group ID with the configured Foundry account host. The separate deployment field identifies the model deployment.

## Named values

- `tenant-id` is created by Bicep.
- `entra-client-id` starts with a placeholder and is updated by the postprovision hook.
- `usage-hmac-key` is a secret named value backed by Key Vault.

## References

- Microsoft Learn: [Azure API Management GenAI gateway capabilities](https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities)
- Microsoft Learn: [`llm-content-safety` policy](https://learn.microsoft.com/azure/api-management/llm-content-safety-policy)
- Microsoft Learn: [`llm-emit-token-metric` policy](https://learn.microsoft.com/azure/api-management/llm-emit-token-metric-policy)
- Microsoft Learn: [`log-to-eventhub` policy](https://learn.microsoft.com/azure/api-management/log-to-eventhub-policy)
- Microsoft Learn: [API Management policy expressions](https://learn.microsoft.com/azure/api-management/api-management-policy-expressions)
