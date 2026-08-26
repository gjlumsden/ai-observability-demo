# Foundry prompt agents

Prompt agents are data-plane resources. Bicep deploys the Foundry account, project, and model. The post-deploy hook creates or updates the agent.

The implementation uses the current Foundry v1 agent definition.

## Weather forecasting agent

`weather-forecast/agent.json` defines:

- GPT-5.4 with `low` reasoning.
- One MCP server.
- One allow-listed read-only APIM MCP tool.
- No tool approval because the tool is read-only and idempotent.
- Instructions that treat MCP output as untrusted data.

`scripts/configure-weather-agent.ps1` creates the APIM MCP connection, resolves the agent placeholders, and upserts the agent.

The backend credential is generated during provisioning. It is stored in App Service and an APIM named value.

Foundry stores only the APIM subscription key in its project connection. The agent uses that connection to call the APIM-native MCP server.
