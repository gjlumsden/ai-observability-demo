# Third-party notices

## Microsoft FinOps toolkit

This repository includes the Microsoft FinOps toolkit FinOps hub v14 release.

- Copyright: Microsoft Corporation
- License: MIT
- Source: https://github.com/microsoft/finops-toolkit
- Source commit: `f3b1b23f3ea6044bcd8cb767620cdd43704ce90a`
- Release asset: `finops-hub-v14.zip`
- SHA-256: `cd8cae56daa324552efad711ff0f23cdb1b671e9eae215b95861029311dc8ca2`

The complete license is in `infra/vendor/finops-toolkit/v14/LICENSE`.

## Azure Verified Modules

This deployment references the Event Hubs namespace Azure Verified Module from the
public Bicep registry. The registry supplies the module at build time.

- Copyright: Microsoft Corporation
- License: MIT
- Module: `avm/res/event-hub/namespace`
- Version: `0.15.0`
- Registry reference: `br/public:avm/res/event-hub/namespace:0.15.0`
- Source: https://github.com/Azure/bicep-registry-modules/tree/avm/res/event-hub/namespace/0.15.0/avm/res/event-hub/namespace

## Azure-Samples/claude

The Claude on Foundry deployment shape is adapted from the Microsoft-maintained
Azure-Samples/claude sample.

- Copyright: Microsoft Corporation
- License: MIT
- Source: https://github.com/Azure-Samples/claude
- Reference file: `infra-bicep/infra/foundry.bicep`

## GOV.UK Frontend

The web application uses the GOV.UK Frontend design system.

- Copyright: Crown Copyright (Government Digital Service)
- License: MIT
- Source: https://github.com/alphagov/govuk-frontend

## Community inspiration

A community repository provided early inspiration for this project. It is not an
authoritative source. It is not a Microsoft reference implementation. This project
credits the source. No file-level analysis establishes that specific code was
copied from it, so this project does not claim verified reuse of its content. The
Microsoft original repositories and platform features are the authoritative
references.

- Source: https://github.com/lestermarch/core-ai-platform-demo
- Pinned commit: `3724a540e22740006eddbff5055e52046a2b1719`
- License: none declared

See [docs/composition-and-upstreams.md](docs/composition-and-upstreams.md) for the
complete provenance matrix and attribution detail.
