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
- `llm-emit-token-metric` emits token metrics with user, subscription, operation, region and API dimensions.
- CORS, correlation ID handling and header cleanup are applied globally.

APIM sends gateway logs to Log Analytics and requests, dependencies, exceptions, and custom token metrics to Application Insights.

## Telemetry destinations

| Destination | Configuration | Data |
| --- | --- | --- |
| Application Insights | `applicationinsights` APIM diagnostic, 100% sampling | Requests, dependencies, exceptions, correlation, and custom token metrics |
| Log Analytics | `GatewayLogs` | Request, API, operation, product, subscription, user-owner, response, latency, region, and caller-IP metadata |
| Log Analytics | `GatewayLlmLogs` | Model, deployment, API version, request, and token metadata |
| Log Analytics | `AllMetrics` | APIM platform metrics in `AzureMetrics` |
| Native APIM Analytics | Gateway and LLM resource logs | Timeline, geography, APIs, operations, products, subscriptions, users, requests, and language models |

The LLM diagnostic sets `largeLanguageModel.logs` to `enabled`. It does not set request or response message logging.

`RequestMessages` and `ResponseMessages` remain empty. Query parameters are hidden in the Azure Monitor diagnostic.

The Presenter, Research, and Engineering APIM users are synthetic subscription owners. They populate native Analytics user dimensions without changing Entra authentication.

Native APIM metrics remain available in Azure Monitor Metrics independently of the resource diagnostic.

## Named values

- `tenant-id` is created by Bicep.
- `entra-client-id` starts with a placeholder and is updated by the postprovision hook.

## References

- Microsoft Learn: [Azure API Management GenAI gateway capabilities](https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities)
- Microsoft Learn: [`llm-content-safety` policy](https://learn.microsoft.com/azure/api-management/llm-content-safety-policy)
- Microsoft Learn: [`llm-emit-token-metric` policy](https://learn.microsoft.com/azure/api-management/llm-emit-token-metric-policy)
