# RAI-ADR-002: Scientific code scenarios

## Status

Accepted.

## Context

The visible application journeys use scientific software engineering tasks to generate observable model traffic.

The system explains and reviews code. It does not make scientific, operational, employment, or public-service decisions.

The feature is user-facing and processes code supplied by a signed-in user. Source code can contain proprietary information, personal data, secrets, or embedded prompt attacks.

## Decision

Expose two journeys:

- Governed Model Comparison sends the same coding task to GPT and Claude.
- Scientific Code Explainer sends one coding task to the managed GPT deployment.

Use approved public or demo code only.

Do not log prompt or completion bodies in routine diagnostics.

Use Prompt Shields in block mode for user prompt attacks.

Use Protected Material for Code in filter mode on GPT completions.

Return successful model output from the protected-material sample. Clearly label that the model guardrail did not block it.

Run the generated code through the Protected Material for Code API as a separate direct check. Keep the model guardrail outcome and direct detector outcome distinct.

Inspect the Azure Responses API `content_filters` extension on HTTP 200 responses. Treat `blocked: true` as a guardrail block and do not display partial completion text.

Use a generic blocked-result message. Do not state that a user is malicious or that blocked output infringes copyright.

Render model Markdown on the server. Disable raw HTML and sanitize the generated HTML before returning it to the browser. Do not allow images, scripts, event handlers, or unsafe URL schemes.

Require human review for:

- Numerical correctness.
- Units and coordinate assumptions.
- Missing-value handling.
- Reproducibility.
- Security.
- Dependency and license compliance.

## Accessibility

Use native buttons and labelled textareas.

Make every sample prompt available through keyboard navigation.

Use text and an icon for blocked results. Do not communicate status through color only.

Announce result changes through an `aria-live` region.

Move focus to the textarea after a sample is selected.

## Privacy and inclusion

The scenarios do not require names, demographic data, location data, or other personal information.

Do not use different model behavior based on protected characteristics.

Support valid Unicode in user-provided code and comments.

Provide clear errors for empty and oversized input.

## Limitations

Protected Material for Code scans generated output and is nondeterministic for a generation prompt.

The code index is current only through April 6, 2023 and supports English.

One prompt is not enough to compare model quality. The comparison journey demonstrates observable requests, not a model selection conclusion.

The application does not prove Customer Copyright Commitment compliance by itself. Retain the required configuration and evaluation evidence.

## References

- [Prompt Shields in Microsoft Foundry](https://learn.microsoft.com/azure/foundry/openai/concepts/content-filter-prompt-shields)
- [Protected Material for Code quickstart](https://learn.microsoft.com/azure/ai-services/content-safety/quickstart-protected-material-code)
- [Customer Copyright Commitment required mitigations](https://learn.microsoft.com/azure/ai-foundry/responsible-ai/openai/customer-copyright-commitment)
