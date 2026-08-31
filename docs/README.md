# Documentation

Use this index to find setup, operation, architecture, demonstration, and design material.

## Start and operate

| Document | Purpose |
| --- | --- |
| [Runbook](RUNBOOK.md) | Deploy, verify, operate, troubleshoot, and remove the Azure resources. |
| [Architecture](architecture.md) | Review the two resource groups and their data flows. |
| [Observability and cost management](observability-and-cost-management.md) | Understand telemetry, attribution, cost data, privacy boundaries, and operational gaps. |

## Present the scenarios

| Document | Purpose |
| --- | --- |
| [AI usage and cost governance demo](cost-governance-demo.md) | Run the complete observability and cost walkthrough. |
| [Scientific software engineering guide](scientific-software-engineering-guide.md) | Prepare and run the model comparison and code guardrail scenarios. |
| [Presenter run script](../demo-scripts/run-demo.md) | Follow the short presenter sequence. |
| [Interactive presenter](../demo-scripts/presenter.html) | Use the local, single-page presentation. |

Open `demo-scripts/presenter.html` directly for the static guide.
Open the configured presenter after deployment with:

```powershell
pwsh ./demo-scripts/open-presenter.ps1 -Slide 1 -Range 24h
```

## Controls and design decisions

| Document | Purpose |
| --- | --- |
| [Guardrails](guardrails.md) | Review the active application, gateway, model, and agent controls. |
| [Code generation guardrails decision](responsible-ai/RAI-ADR-001-code-generation-guardrails.md) | Review the code safety control decision. |
| [Scientific code scenarios decision](responsible-ai/RAI-ADR-002-scientific-code-scenarios.md) | Review the scenario, accessibility, privacy, and human-review decisions. |

## Component notes

| Document | Purpose |
| --- | --- |
| [APIM policy set](../apim-policies/README.md) | Review model routes, policies, telemetry, and named values. |
| [Foundry prompt agents](../agents/README.md) | Review the weather agent and MCP connection. |
| [Web application](../src/web/README.md) | Run and configure the Express application. |

Find the deployment source files for both Azure Monitor dashboards and the Workbook in
[`infra/dashboards`](../infra/dashboards) and [`infra/workbooks`](../infra/workbooks).
