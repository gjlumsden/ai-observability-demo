$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$mcpConnectionName = 'weather-mcp-apim-v1'
$agentName = 'weather-forecast-agent'
$connectionsExtensionVersion = '1.0.0-beta.4'

function Get-AzdEnvironmentValues {
    $values = @{}
    $output = azd env get-values --cwd $repoRoot 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not read the active azd environment.'
    }

    foreach ($line in $output) {
        if ($line -match '^\s*([^=]+)=(.*)\s*$') {
            $values[$Matches[1].Trim()] = $Matches[2].Trim().Trim('"')
        }
    }
    return $values
}

function Get-RequiredValue {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Values,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($Values.ContainsKey($Name) -and $Values[$Name]) {
        return $Values[$Name]
    }
    throw "$Name is not configured."
}

$values = Get-AzdEnvironmentValues
$resourceGroup = Get-RequiredValue $values 'AZURE_RESOURCE_GROUP'
$foundryName = Get-RequiredValue $values 'FOUNDRY_NAME'
$subscriptionId = Get-RequiredValue $values 'AZURE_SUBSCRIPTION_ID'
$apimName = Get-RequiredValue $values 'APIM_NAME'
$mcpUrl = Get-RequiredValue $values 'WEATHER_MCP_API_URL'
$mcpSubscriptionId = Get-RequiredValue $values 'WEATHER_MCP_SUBSCRIPTION_ID'
$weatherAgentModelName = Get-RequiredValue $values 'WEATHER_AGENT_MODEL_NAME'
$applicationInsightsId = Get-RequiredValue $values 'APPLICATION_INSIGHTS_ID'
$projectEndpoint = "https://$foundryName.services.ai.azure.com/api/projects/governed-model-comparison"

$extensionsJson = azd extension list --output json
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the Azure Developer CLI extensions.'
}
$extensions = $extensionsJson -join "`n" | ConvertFrom-Json
$connectionsExtension = $extensions |
    Where-Object { $_.id -eq 'azure.ai.connections' } |
    Select-Object -First 1
if ($connectionsExtension.installedVersion -ne $connectionsExtensionVersion) {
    azd extension install azure.ai.connections `
        --version $connectionsExtensionVersion `
        --force `
        --no-prompt
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not install the pinned Foundry Connections extension.'
    }
}
$subscriptionSecretsUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.ApiManagement/service/$apimName/subscriptions/$mcpSubscriptionId/listSecrets?api-version=2025-09-01-preview"
$subscriptionSecretsJson = az rest `
    --only-show-errors `
    --method post `
    --uri $subscriptionSecretsUri `
    --output json
if ($LASTEXITCODE -ne 0) {
    throw 'Could not read the weather MCP subscription key.'
}
$mcpSubscriptionKey = (($subscriptionSecretsJson -join "`n") | ConvertFrom-Json).primaryKey
if (-not $mcpSubscriptionKey) {
    throw 'The weather MCP subscription has no primary key.'
}

azd ai connection create $mcpConnectionName `
    --project-endpoint $projectEndpoint `
    --kind remote-tool `
    --target $mcpUrl `
    --auth-type custom-keys `
    --custom-key "Ocp-Apim-Subscription-Key=$mcpSubscriptionKey" `
    --force `
    --no-prompt `
    --output json | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Could not create the weather MCP project connection.'
}

$agentDefinitionPath = Join-Path $repoRoot 'agents\weather-forecast\agent.json'
if (-not (Test-Path -LiteralPath $agentDefinitionPath)) {
    throw "Weather agent definition not found: $agentDefinitionPath"
}
$agentDefinitionJson = Get-Content -LiteralPath $agentDefinitionPath -Raw
$agentDefinitionJson = $agentDefinitionJson.Replace('__WEATHER_MCP_URL__', $mcpUrl)
$agentDefinitionJson = $agentDefinitionJson.Replace('__WEATHER_MCP_CONNECTION_NAME__', $mcpConnectionName)
$agentDefinitionJson = $agentDefinitionJson.Replace('__WEATHER_AGENT_MODEL_NAME__', $weatherAgentModelName)
$agentDefinition = $agentDefinitionJson | ConvertFrom-Json

$existing = az rest `
    --only-show-errors `
    --method get `
    --uri "$projectEndpoint/agents/$agentName`?api-version=v1" `
    --resource 'https://ai.azure.com' `
    --output none 2>$null
$agentUri = if ($LASTEXITCODE -eq 0) {
    "$projectEndpoint/agents/$agentName`?api-version=v1"
}
else {
    "$projectEndpoint/agents?api-version=v1"
}

$agentFile = [System.IO.Path]::GetTempFileName()
try {
    $agentDefinition | ConvertTo-Json -Depth 20 |
        Set-Content -LiteralPath $agentFile -Encoding utf8NoBOM -NoNewline
    az rest `
        --only-show-errors `
        --method post `
        --uri $agentUri `
        --resource 'https://ai.azure.com' `
        --headers 'Content-Type=application/json' `
        --body "@$agentFile" `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not create or update the weather forecasting agent.'
    }
}
finally {
    Remove-Item -LiteralPath $agentFile -Force -ErrorAction SilentlyContinue
}

$agentJson = az rest `
    --only-show-errors `
    --method get `
    --uri "$projectEndpoint/agents/$agentName`?api-version=v1" `
    --resource 'https://ai.azure.com' `
    --output json
if ($LASTEXITCODE -ne 0) {
    throw 'Could not read the configured weather agent identity.'
}
$agent = ($agentJson -join "`n") | ConvertFrom-Json
$agentPrincipalId = $agent.versions.latest.instance_identity.principal_id
if (-not $agentPrincipalId) {
    throw 'The configured weather agent returned no agent identity.'
}

$traceRole = 'Monitoring Metrics Publisher'
$traceRoleAssignment = az role assignment list `
    --assignee-object-id $agentPrincipalId `
    --scope $applicationInsightsId `
    --role $traceRole `
    --query '[0].id' `
    --output tsv
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the weather agent trace role assignment.'
}
if (-not $traceRoleAssignment) {
    az role assignment create `
        --assignee-object-id $agentPrincipalId `
        --assignee-principal-type ServicePrincipal `
        --role $traceRole `
        --scope $applicationInsightsId `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not grant the weather agent permission to publish traces.'
    }
}

azd env set WEATHER_AGENT_NAME $agentName --cwd $repoRoot | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Could not store the weather agent name in the azd environment.'
}

Write-Host "Weather agent configured: $agentName" -ForegroundColor Green
