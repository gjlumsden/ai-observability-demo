$ErrorActionPreference = 'Stop'

function Get-AzdEnvironmentValues {
    $values = @{}
    $output = azd env get-values 2>$null
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
        [Parameter(Mandatory = $true)][hashtable] $Values,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ($envValue = [Environment]::GetEnvironmentVariable($Name)) {
        return $envValue
    }
    if ($Values.ContainsKey($Name) -and $Values[$Name]) {
        return $Values[$Name]
    }
    throw "$Name is not configured."
}

$values = Get-AzdEnvironmentValues
$webAppName = Get-RequiredValue $values 'WEB_APP_NAME'
$apimGatewayUrl = (Get-RequiredValue $values 'APIM_GATEWAY_URL').TrimEnd('/')
$foundryEndpoint = (Get-RequiredValue $values 'FOUNDRY_ENDPOINT').TrimEnd('/')
$weatherMcpUrl = Get-RequiredValue $values 'WEATHER_MCP_API_URL'
$webAppUrl = "https://$webAppName.azurewebsites.net"
$healthUrl = "$webAppUrl/healthz"

Write-Host ''
Write-Host 'AI Observability Demo post-deploy checks' -ForegroundColor Cyan

$healthy = $false
for ($attempt = 1; $attempt -le 12; $attempt++) {
    try {
        $response = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 30
        if ($response.StatusCode -eq 200) {
            $healthy = $true
            break
        }
    }
    catch {
        if ($attempt -eq 12) {
            throw "Web health check failed after 12 attempts: $($_.Exception.Message)"
        }
    }
    Start-Sleep -Seconds 10
}

if (-not $healthy) {
    throw 'The web health endpoint did not return HTTP 200.'
}

Write-Host 'Web health check passed.' -ForegroundColor Green

& (Join-Path $PSScriptRoot '..\scripts\configure-weather-agent.ps1')

Write-Host "Start page:       $webAppUrl"
Write-Host "Model comparison: $webAppUrl/model-comparison"
Write-Host "Code explainer:   $webAppUrl/scientific-code-explainer"
Write-Host "APIM gateway:     $apimGatewayUrl"
Write-Host "Foundry endpoint: $foundryEndpoint"
Write-Host "Weather MCP:      $weatherMcpUrl"
Write-Host 'Run script:       ./demo-scripts/run-demo.md'
