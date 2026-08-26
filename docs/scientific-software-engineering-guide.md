# Scientific software engineering scenario guide

## Purpose

The two scenarios create clear, repeatable traffic for platform configuration and observability.

Keep the scenario explanation short. The main subjects are:

- Approved model configuration.
- Team and user attribution.
- Token use, latency, quota, and cost.
- Prompt Shields and Protected Material for Code.
- Central controls with a low-friction developer experience.

Use approved public or demo code only. Do not enter proprietary source code, secrets, or personal data.

## Preparation

Before the session:

1. Confirm GPT-5.4 and Claude Opus 5 are available through APIM.
2. Confirm the presenter product requires a validated Entra token.
3. Confirm `rai-ai-observability-demo` is assigned to GPT-5.4.
4. Confirm Prompt Shields for user prompt attacks uses block mode.
5. Confirm Protected Material for Code uses filter mode.
6. Confirm the OpenAI gateway policy adds the copyright safety instruction.
7. Open the web app, APIM analytics, Application Insights, the usage workbook, Foundry guardrails, and Cost Management.
8. Confirm the workbook contains recent generated traffic.
9. Sign in to the web app.

Do not show subscription keys, access tokens, tenant identifiers, or application secrets.

## Scenario 1: Governed Model Comparison

Open **Governed Model Comparison**.

Select **Review scientific Python**. The prompt asks both models to review this function:

```python
def daily_rainfall_total(values_mm):
    return sum(value for value in values_mm if value is not None)
```

Select **Compare models**.

Keep the code discussion brief. State that this is a representative scientific engineering task, not a meteorological decision.

Show:

- The same prompt went to GPT-5.4 and Claude Opus 5.
- Both calls used the same validated user and gateway correlation ID.
- Each provider returned its own token counts.
- The gateway returned the team, quota, and attribution metadata.
- Latency and output size differ between models.

Then show the corresponding request window in APIM or Application Insights. Use `x-correlation-id` if the view exposes captured request headers.

In the workbook, focus on:

- Requests by model.
- Input, output, and total tokens.
- Team and user attribution.
- P50 and P95 latency.
- Quota responses.
- Data freshness.

Do not present one response as a statistically valid model benchmark. It is one observable comparison request.

## Scenario 2: Scientific Code Explainer

Open **Scientific Code Explainer**.

Select **Explain rainfall aggregation**, then select **Explain code**.

Show:

- The request used the organisation-managed GPT deployment.
- The answer identifies purpose, assumptions, missing-value behavior, and tests.
- The page shows token, latency, quota, model, and correlation metadata.
- The prompt and completion bodies are not included in routine telemetry.

Use **Explain anomaly calculation** to create a second request with different token use.

The model output is advisory. A scientific software engineer must review numerical correctness, units, tolerances, tests, and licensing.

## Prompt Shield demonstration

In **Scientific Code Explainer**, select **Prompt Shield test**.

The sample is based on the official Microsoft prompt-attack example. It attempts to replace the assistant persona and remove restrictions.

Expected result:

- Foundry returns a content-filter block.
- The page shows a generic safety message.
- The page does not claim that the user acted maliciously.
- The control is shown as `prompt_shield` when the service returns detailed filter data.

If the request is not blocked:

1. Confirm the guardrail is assigned to GPT-5.4.
2. Confirm the user prompt attack intervention point is enabled.
3. Confirm the action is block.
4. Repeat with the official Microsoft sample from the Prompt Shields documentation.

## Protected Material for Code demonstration

In **Scientific Code Explainer**, select **Protected material test**.

The sample asks the model to create a detailed Pygame keyboard-movement example. It does not include third-party source code in the repository.

Protected Material for Code scans the model completion, not the user prompt. The result is not deterministic because the model can refuse, summarize, or produce original code.

Expected gateway result when the model completion triggers the deployment guardrail:

- Azure Responses API can return HTTP 200 with `content_filters[].blocked=true`.
- Input blocks can return HTTP 400 with `content_filter`.
- The page shows a blocked result and no generated code.
- The request remains visible in operational telemetry.

If the model guardrail does not return a block, the page displays the model response. The server then extracts generated code and calls the Protected Material for Code API directly.

The page reports two separate outcomes:

- **Model guardrail** — blocked or no block returned.
- **Direct Protected Material for Code check** — detected, not detected, or check failed.

For deterministic control evidence:

1. Open the **Check code directly** section in Scientific Code Explainer.
2. Keep the prefilled Microsoft sample.
3. Select **Check code directly**.
4. Confirm **Detected** and review the returned license and source URLs.
5. Use the linked [Protected Material for Code quickstart](https://learn.microsoft.com/azure/ai-services/content-safety/quickstart-protected-material-code) to explain the sample.

You can also run the same sample in Foundry **Guardrails + controls** > **Try it out**.

State these limitations:

- The code index is current only through April 6, 2023.
- The control supports English.
- A clear result is not legal approval.
- A block is a safety signal, not proof of copyright infringement.
- Normal code, security, dependency, and license review remain required.

## Configuration narrative

Use this short narrative:

> Developers use familiar scientific coding tasks. The platform team controls which models they can access, where requests are processed, how code-generation guardrails operate, and how usage is attributed. The scenarios are intentionally simple so the control and observability evidence remains clear.

## Evidence to retain

Capture:

- The assigned GPT guardrail configuration.
- Prompt Shield and Protected Material for Code modes.
- The gateway policy revision.
- One normal request correlation ID.
- One blocked Prompt Shield request.
- The official Protected Material for Code test result.
- The workbook time range containing the requests.
- The dependency and security review result.

The Customer Copyright Commitment also requires the copyright safety instruction and retained evaluation evidence. See [Customer Copyright Commitment required mitigations](https://learn.microsoft.com/azure/ai-foundry/responsible-ai/openai/customer-copyright-commitment).

## Fallbacks

| Condition | Fallback |
| --- | --- |
| Claude is unavailable | Run the GPT request and explain that model access is centrally configured. |
| Workbook data is delayed | Use APIM request metadata and explain ingestion delay. |
| Protected-code generation does not block | Use the official Foundry detection sample. |
| Prompt Shield does not block | Verify guardrail assignment and use the official Microsoft prompt sample. |
| Cost data is delayed | Show token telemetry and explain that Cost Management is the billing source of truth. |

## References

- [Prompt Shields in Microsoft Foundry](https://learn.microsoft.com/azure/foundry/openai/concepts/content-filter-prompt-shields)
- [Protected Material for Code quickstart](https://learn.microsoft.com/azure/ai-services/content-safety/quickstart-protected-material-code)
- [Protected material detection filter](https://learn.microsoft.com/azure/foundry/openai/concepts/content-filter-protected-material)
- [Customer Copyright Commitment required mitigations](https://learn.microsoft.com/azure/ai-foundry/responsible-ai/openai/customer-copyright-commitment)
- [Observability and cost management](observability-and-cost-management.md)
