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

function Invoke-AzJson {
    param(
        [Parameter(Mandatory = $true)][string] $Area,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "${Area}: $($output -join "`n")"
    }
    return ($output -join "`n" | ConvertFrom-Json)
}

function Invoke-Az {
    param(
        [Parameter(Mandatory = $true)][string] $Area,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "${Area}: $($output -join "`n")"
    }
}

$values = Get-AzdEnvironmentValues
$resourceGroup = Get-RequiredValue $values 'AZURE_RESOURCE_GROUP'
$tenantId = Get-RequiredValue $values 'AZURE_TENANT_ID'
$webAppName = Get-RequiredValue $values 'WEB_APP_NAME'
$apimName = Get-RequiredValue $values 'APIM_NAME'
$finOpsWorkflowName = Get-RequiredValue $values 'FINOPS_SNAPSHOT_WORKFLOW_NAME'
$weatherMcpBackendKeyNamedValueId = Get-RequiredValue $values 'WEATHER_MCP_BACKEND_KEY_NAMED_VALUE_ID'
$webAppUrl = "https://$webAppName.azurewebsites.net"
$redirectUri = "$webAppUrl/auth/callback"
$displayName = "AI Observability Demo - $webAppName"
$existingClientId = [Environment]::GetEnvironmentVariable('ENTRA_CLIENT_ID')
if (-not $existingClientId -and $values.ContainsKey('ENTRA_CLIENT_ID')) {
    $existingClientId = $values['ENTRA_CLIENT_ID']
}

Write-Host ''
Write-Host 'Configuring Entra sign-in' -ForegroundColor Cyan

$app = if ($existingClientId) {
    Invoke-AzJson 'Entra app lookup by client ID' @(
        'ad', 'app', 'show',
        '--only-show-errors',
        '--id', $existingClientId,
        '--output', 'json'
    )
}
else {
    $apps = Invoke-AzJson 'Entra app lookup by display name' @(
        'ad', 'app', 'list',
        '--only-show-errors',
        '--display-name', $displayName,
        '--output', 'json'
    )
    $apps | Select-Object -First 1
}

if (-not $app) {
    $app = Invoke-AzJson 'Entra app create' @(
        'ad', 'app', 'create',
        '--only-show-errors',
        '--display-name', $displayName,
        '--web-redirect-uris', $redirectUri,
        '--sign-in-audience', 'AzureADMyOrg',
        '--output', 'json'
    )
}
else {
    Invoke-Az 'Entra app update' @(
        'ad', 'app', 'update',
        '--only-show-errors',
        '--id', $app.appId,
        '--display-name', $displayName,
        '--web-redirect-uris', $redirectUri,
        '--output', 'none'
    )
}

$appDetails = Invoke-AzJson 'Entra app details' @(
    'ad', 'app', 'show',
    '--only-show-errors',
    '--id', $app.appId,
    '--output', 'json'
)

$scopeValue = 'access_as_user'
$existingScope = $appDetails.api.oauth2PermissionScopes |
    Where-Object { $_.value -eq $scopeValue } |
    Select-Object -First 1
$scopeId = if ($existingScope) { $existingScope.id } else { [guid]::NewGuid().ToString() }

Invoke-Az 'Entra identifier URI' @(
    'ad', 'app', 'update',
    '--only-show-errors',
    '--id', $app.appId,
    '--identifier-uris', "api://$($app.appId)",
    '--output', 'none'
)

$scopeBody = @{
    api = @{
        oauth2PermissionScopes = @(
            @{
                adminConsentDescription = 'Access the AI Observability Demo as the signed-in user.'
                adminConsentDisplayName = 'Access AI Observability Demo'
                id = $scopeId
                isEnabled = $true
                type = 'User'
                userConsentDescription = 'Access the AI Observability Demo on your behalf.'
                userConsentDisplayName = 'Access AI Observability Demo'
                value = $scopeValue
            }
        )
    }
} | ConvertTo-Json -Depth 10 -Compress

$scopeFile = [System.IO.Path]::GetTempFileName()
try {
    Set-Content -LiteralPath $scopeFile -Value $scopeBody -Encoding utf8NoBOM -NoNewline
    Invoke-Az 'Entra delegated scope' @(
        'rest',
        '--only-show-errors',
        '--method', 'PATCH',
        '--uri', "https://graph.microsoft.com/v1.0/applications/$($appDetails.id)",
        '--headers', 'Content-Type=application/json',
        '--body', "@$scopeFile",
        '--output', 'none'
    )
}
finally {
    Remove-Item -LiteralPath $scopeFile -Force -ErrorAction SilentlyContinue
}

$credential = Invoke-AzJson 'Entra app credential' @(
    'ad', 'app', 'credential', 'reset',
    '--only-show-errors',
    '--id', $app.appId,
    '--append',
    '--display-name', 'azd-demo-hook',
    '--end-date', (Get-Date).ToUniversalTime().AddDays(30).ToString('yyyy-MM-ddTHH:mm:ssZ'),
    '--output', 'json'
)

$sessionSecretBytes = [byte[]]::new(48)
[System.Security.Cryptography.RandomNumberGenerator]::Fill($sessionSecretBytes)
$sessionSecret = [Convert]::ToBase64String($sessionSecretBytes)

$currentSettings = Invoke-AzJson 'Web app settings lookup' @(
    'webapp', 'config', 'appsettings', 'list',
    '--only-show-errors',
    '--resource-group', $resourceGroup,
    '--name', $webAppName,
    '--output', 'json'
)
$mcpWeatherKey = ($currentSettings |
    Where-Object { $_.name -eq 'MCP_WEATHER_KEY' } |
    Select-Object -First 1).value
if (-not $mcpWeatherKey) {
    $mcpKeyBytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($mcpKeyBytes)
    $mcpWeatherKey = [Convert]::ToBase64String($mcpKeyBytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

Invoke-Az 'Web app authentication settings' @(
    'webapp', 'config', 'appsettings', 'set',
    '--only-show-errors',
    '--resource-group', $resourceGroup,
    '--name', $webAppName,
    '--settings',
    "ENTRA_TENANT_ID=$tenantId",
    "ENTRA_CLIENT_ID=$($app.appId)",
    "ENTRA_CLIENT_SECRET=$($credential.password)",
    "ENTRA_SCOPES=api://$($app.appId)/$scopeValue",
    "SESSION_SECRET=$sessionSecret",
    "MCP_WEATHER_KEY=$mcpWeatherKey",
    '--output', 'none'
)

Invoke-Az 'APIM Entra audience' @(
    'apim', 'nv', 'update',
    '--only-show-errors',
    '--resource-group', $resourceGroup,
    '--service-name', $apimName,
    '--named-value-id', 'entra-client-id',
    '--value', $app.appId,
    '--secret', 'false',
    '--output', 'none'
)

Invoke-Az 'APIM weather MCP backend key' @(
    'apim', 'nv', 'update',
    '--only-show-errors',
    '--resource-group', $resourceGroup,
    '--service-name', $apimName,
    '--named-value-id', $weatherMcpBackendKeyNamedValueId,
    '--value', $mcpWeatherKey,
    '--secret', 'true',
    '--output', 'none'
)

$subscriptionId = Get-RequiredValue $values 'AZURE_SUBSCRIPTION_ID'
$workflowResourceUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Logic/workflows/$finOpsWorkflowName"
$snapshotTriggerUri = "$workflowResourceUri/triggers/Daily/run?api-version=2019-05-01"
$snapshotRunsUri = "$workflowResourceUri/runs?api-version=2019-05-01"
$snapshotSucceeded = $false
$snapshotRunInProgress = $false

for ($attempt = 1; $attempt -le 3 -and -not $snapshotSucceeded -and -not $snapshotRunInProgress; $attempt++) {
    $requestedAfter = [DateTime]::UtcNow.AddSeconds(-5)
    & az rest --only-show-errors --method post --uri $snapshotTriggerUri --output none 2>$null
    if ($LASTEXITCODE -ne 0) {
        Start-Sleep -Seconds 20
        continue
    }

    for ($poll = 1; $poll -le 120; $poll++) {
        Start-Sleep -Seconds 5
        $runOutput = & az rest --only-show-errors --method get --uri $snapshotRunsUri --output json 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $runOutput) {
            continue
        }

        $runs = ($runOutput -join "`n" | ConvertFrom-Json)
        $run = $runs.value |
            Where-Object { [DateTime]$_.properties.startTime -ge $requestedAfter } |
            Sort-Object { [DateTime]$_.properties.startTime } -Descending |
            Select-Object -First 1
        if (-not $run) {
            continue
        }

        $snapshotRunInProgress = $true
        if ($run.properties.status -eq 'Succeeded') {
            $snapshotSucceeded = $true
            $snapshotRunInProgress = $false
            break
        }
        if ($run.properties.status -in @('Failed', 'Faulted', 'Cancelled', 'Aborted', 'Skipped', 'TimedOut')) {
            $snapshotRunInProgress = $false
            break
        }
    }

    if (-not $snapshotSucceeded -and -not $snapshotRunInProgress -and $attempt -lt 3) {
        Start-Sleep -Seconds 30
    }
}

if ($snapshotRunInProgress) {
    Write-Warning 'The FinOps snapshot is still running. Review the Logic App run history before using the dashboard.'
}
elseif (-not $snapshotSucceeded) {
    Write-Warning 'The FinOps snapshot did not complete successfully. Review the Logic App run history and run the Daily trigger again.'
}

azd env set ENTRA_CLIENT_ID $app.appId | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Could not store the Entra client ID in the azd environment.'
}

Write-Host ''
Write-Host 'AI Observability Demo post-provision configuration completed.' -ForegroundColor Green
Write-Host "Web app:      $webAppUrl"
Write-Host "Model compare: $webAppUrl/model-comparison"
Write-Host "Code explain:  $webAppUrl/scientific-code-explainer"
Write-Host "FinOps snapshot: $finOpsWorkflowName ($($snapshotSucceeded ? 'Succeeded' : 'Requires review'))"
