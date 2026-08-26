# AI Observability Demo presenter run script

## 0. Preparation

- Sign in to the web app.
- Open the Grafana dashboard, APIM analytics, Application Insights, the usage workbook, Foundry guardrails, and Cost Management.
- Confirm GPT-5.4 and Claude Opus 5 are available through APIM.
- Confirm `rai-ai-observability-demo` is assigned to GPT-5.4.
- Use approved public or demo code only.

## 1. Governed Model Comparison

1. Open **Governed Model Comparison**.
2. Select **Review scientific Python**.
3. Select **Compare models**.
4. Keep the scientific explanation brief.
5. Show the shared correlation ID.
6. Compare model, input tokens, output tokens, total tokens, latency, team, user, and quota metadata.
7. Match the request window in APIM or Application Insights.
8. Show model and team views in the usage workbook.
9. Show the unified request, token, latency, attribution, and freshness panels in Grafana.

Key point:

> The scientific task is deliberately small. The subject is central model access, attribution, controls, and observability.

## 2. Scientific Code Explainer

1. Open **Scientific Code Explainer**.
2. Select **Explain rainfall aggregation**.
3. Select **Explain code**.
4. Show the GPT model, token use, latency, quota, and correlation ID.
5. State that a scientific software engineer must review numerical correctness, units, tests, security, and licensing.

## 3. Prompt Shield

1. Select **Prompt Shield test**.
2. Select **Explain code**.
3. Confirm the page shows a blocked result.
4. Show the corresponding filtered request in telemetry.

Do not describe the user as malicious. State that the platform detected a prompt pattern that attempted to replace system instructions.

## 4. Protected Material for Code

1. Select **Generate and scan code**.
2. Select **Explain code**.
3. If the model guardrail blocks the completion, show the explicit block status.
4. If no block occurs, show the complete model response and the direct detector result.
5. In **Check code directly**, run the prefilled Microsoft sample.
6. Confirm **Detected** and review the license and source citations.

Do not paste proprietary code into the demo.

State:

- Detection scans model output, not the user prompt.
- The code index is current only through April 6, 2023.
- A clear result is not legal approval.
- A block is not proof of copyright infringement.

## 5. Close

Show:

- Team and user attribution.
- Model usage and latency.
- Token quotas.
- Prompt Shield and protected-code controls.
- Cost Management as the billing source of truth.
- The Grafana dashboard as the combined operational and daily financial view.

Use the full [scientific software engineering scenario guide](../docs/scientific-software-engineering-guide.md) for preparation, expected results, limitations, and fallbacks.

## Optional: Weather forecasting agent with MCP

1. Open `weather-forecast-agent` in the Foundry agents view.
2. Select **Plan Balado festival operations**.
3. Confirm the agent calls only `get_weather_forecast`.
4. Show prompt, visible-completion, and reasoning token composition in Grafana.
5. Review the operational impacts, monitoring triggers, and recommended mitigations.
