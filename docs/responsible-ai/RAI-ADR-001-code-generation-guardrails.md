# RAI-ADR-001: Code generation guardrails

## Status

Accepted for the scientific software engineering scenarios.

## Context

The scientific software engineering scenario includes code generation through GPT-5.4. Generated code can match code in known public repositories.

Prompt injection can also attempt to override the application instructions.

The Customer Copyright Commitment requires these controls for Azure OpenAI code generation:

- Protected Material Code must use annotate or filter mode.
- Prompt Shields for direct jailbreak attacks must use filter mode.
- Annotate mode requires compliance with each cited license.

## Decision

Apply the `rai-ai-observability-demo` policy to all Azure OpenAI deployments.

Configure:

- `Protected Material Code` on completions with `enabled: true` and `blocking: true`.
- `Jailbreak` on prompts with `enabled: true` and `blocking: true`.
- `Indirect Attack` on prompts with `enabled: true` and `blocking: true`.
- A copyright safety instruction on every OpenAI Responses API request.

Use filter mode for Protected Material Code in this demo. Filter mode gives a clear blocked result and avoids a license-review workflow.

Keep protected material text detection enabled in annotate mode for open text output.

## Responsible AI effects

The filters make automated decisions about user prompts and generated code. False positives can block valid work.

Use a generic user-facing explanation. Do not imply that a blocked result proves copyright infringement.

The protected material model supports English. Its code index is current only through April 6, 2023.

Indirect-attack detection depends on the Microsoft document-delimiting format for retrieved content.

Do not treat a clear result as legal approval. Require normal code review, dependency review, security scanning, and license review.

The policy adds no personal-data collection. Routine APIM diagnostics continue to exclude prompt and completion bodies.

## Verification

Verify the deployed policy through the Azure resource API and the Foundry portal.

Verify that the APIM OpenAI policy replaces caller-supplied model and instruction values.

Use the official Microsoft Protected Material for Code sample in the Foundry **Try it out** experience.

Use a benign direct-attack prompt to verify Prompt Shields. Do not use proprietary code or personal data.

Retain the test result and configuration evidence if Customer Copyright Commitment coverage is required.

## References

- [Customer Copyright Commitment required mitigations](https://learn.microsoft.com/azure/ai-foundry/responsible-ai/openai/customer-copyright-commitment)
- [Configure content filters](https://learn.microsoft.com/azure/ai-foundry/openai/how-to/content-filters)
- [Protected material detection](https://learn.microsoft.com/azure/ai-services/content-safety/concepts/protected-material)
- [Protected Material for Code quickstart](https://learn.microsoft.com/azure/ai-services/content-safety/quickstart-protected-material-code)
