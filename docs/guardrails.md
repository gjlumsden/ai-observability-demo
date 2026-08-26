# Guardrails

## Active control layers

| Layer | Controls |
| --- | --- |
| Web | Entra sign-in, input length limits, encoded output rendering, safe Markdown, and explicit guardrail status handling |
| API Management | Entra token validation, team/user attribution, token quotas, Content Safety, managed identity, and request-body exclusion from diagnostics |
| Foundry | `rai-ai-observability-demo`, Prompt Shields, harm filters, protected material text, and Protected Material for Code |
| Weather MCP | APIM subscription, protected backend operation, one allow-listed read-only tool, strict inputs, bounded timeout, and no key logging |
| Engineering process | Human review, testing, security scanning, dependency review, and license review |

## Scientific Code Explainer

The normal samples use Python and Fortran.

The Prompt Shield sample uses the official Microsoft attack pattern that attempts to replace the assistant persona.

The generated-code sample asks for an original Pygame program. The application returns complete unblocked output and scans generated code directly.

Protected Material for Code scans the model completion. It does not scan the user prompt.

Azure Responses API completion blocks can arrive with HTTP 200 and `content_filters[].blocked=true`. The application treats this as a block and does not display partial output.

The separate direct-check form calls Protected Material for Code without model generation. Its default Microsoft sample returns a repeatable detection with citations.

The web application emits `guardrail.decision` events with guardrail, stage, outcome, and correlation ID. It does not include code or prompt bodies.

## Weather agent model route

The internal model route keeps Prompt Shields enabled. APIM completion inspection is disabled because it removes streamed tool-call output.

The GPT-5.4 deployment applies its Foundry RAI policy to model input and output.

## Limits

- The protected-code index is current only through April 6, 2023.
- Protected Material for Code supports English.
- One request is not a model benchmark.
- A clear result is not legal approval.
- A block is a safety signal, not proof of copyright infringement.
- Prompt and completion bodies are excluded from routine APIM diagnostics.
- The weather tool uses an external demo data source. Results are not official forecast guidance.

## Verification

Use the [scientific software engineering scenario guide](scientific-software-engineering-guide.md).

For deterministic protected-code evidence, use the official Microsoft sample in Foundry **Guardrails + controls** > **Try it out**.

## References

- [Prompt Shields in Microsoft Foundry](https://learn.microsoft.com/azure/foundry/openai/concepts/content-filter-prompt-shields)
- [Protected Material for Code quickstart](https://learn.microsoft.com/azure/ai-services/content-safety/quickstart-protected-material-code)
- [Customer Copyright Commitment required mitigations](https://learn.microsoft.com/azure/ai-foundry/responsible-ai/openai/customer-copyright-commitment)
