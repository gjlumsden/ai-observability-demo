$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot

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

function Invoke-AzText {
    param(
        [Parameter(Mandatory = $true)][string] $Area,
        [Parameter(Mandatory = $true)][string[]] $Arguments
    )

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "${Area}: $($output -join "`n")"
    }
    return ($output -join "`n").Trim()
}

function Get-OptionalEntraApplicationByClientId {
    param(
        [Parameter(Mandatory = $true)][string] $ClientId
    )

    $output = & az ad app show `
        --only-show-errors `
        --id $ClientId `
        --output json 2>&1
    if ($LASTEXITCODE -eq 0) {
        return ($output -join "`n" | ConvertFrom-Json)
    }

    $message = $output -join "`n"
    if ($message -match 'does not exist|could not be found|cannot find|not found') {
        Write-Warning "ENTRA_CLIENT_ID $ClientId does not resolve to an existing Entra app. The hook will create or reuse a replacement registration."
        return $null
    }

    throw "Entra app lookup by client ID: $message"
}

$values = Get-AzdEnvironmentValues
$resourceGroup = Get-RequiredValue $values 'AZURE_RESOURCE_GROUP'
$tenantId = Get-RequiredValue $values 'AZURE_TENANT_ID'
$entraLoginEndpoint = Invoke-AzText 'Azure cloud Active Directory endpoint' @(
    'cloud', 'show',
    '--only-show-errors',
    '--query', 'endpoints.activeDirectory',
    '--output', 'tsv'
)
$entraIssuer = '{0}/{1}/v2.0' -f $entraLoginEndpoint.TrimEnd('/'), $tenantId
$webAppName = Get-RequiredValue $values 'WEB_APP_NAME'
$apimName = Get-RequiredValue $values 'APIM_NAME'
$finOpsHubName = Get-RequiredValue $values 'FINOPS_HUB_NAME'
$weatherMcpBackendKeyNamedValueId = Get-RequiredValue $values 'WEATHER_MCP_BACKEND_KEY_NAMED_VALUE_ID'
$webAppUrl = "https://$webAppName.azurewebsites.net"
$redirectUri = "$webAppUrl/.auth/login/aad/callback"
$displayName = "AI Observability Demo - $webAppName"
$existingClientId = [Environment]::GetEnvironmentVariable('ENTRA_CLIENT_ID')
if (-not $existingClientId -and $values.ContainsKey('ENTRA_CLIENT_ID')) {
    $existingClientId = $values['ENTRA_CLIENT_ID']
}

$bootstrapRoleAssignmentId = Get-RequiredValue $values 'HMAC_BOOTSTRAP_ROLE_ASSIGNMENT_ID'
$bootstrapRoleOutput = & az role assignment delete `
    --only-show-errors `
    --ids $bootstrapRoleAssignmentId 2>&1
$bootstrapRoleExitCode = $LASTEXITCODE
if ($bootstrapRoleExitCode -ne 0 -and ($bootstrapRoleOutput -join "`n") -notmatch 'RoleAssignmentNotFound|could not be found') {
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        Start-Sleep -Seconds 10
        $bootstrapRoleOutput = & az role assignment delete `
            --only-show-errors `
            --ids $bootstrapRoleAssignmentId 2>&1
        $bootstrapRoleExitCode = $LASTEXITCODE
        if ($bootstrapRoleExitCode -eq 0 -or ($bootstrapRoleOutput -join "`n") -match 'RoleAssignmentNotFound|could not be found') {
            break
        }
    }
    if ($bootstrapRoleExitCode -ne 0 -and ($bootstrapRoleOutput -join "`n") -notmatch 'RoleAssignmentNotFound|could not be found') {
        throw "Temporary HMAC bootstrap access removal failed: $($bootstrapRoleOutput -join "`n")"
    }
}

& (Join-Path $PSScriptRoot 'deploy-finops-hub.ps1')
$values = Get-AzdEnvironmentValues

Write-Host ''
Write-Host 'Configuring App Service authentication' -ForegroundColor Cyan

$app = if ($existingClientId) {
    Get-OptionalEntraApplicationByClientId -ClientId $existingClientId
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

$workingDirectory = Join-Path $repoRoot '.azure'
New-Item -ItemType Directory -Force -Path $workingDirectory | Out-Null
$scopeFile = Join-Path $workingDirectory "postprovision-scope-$PID.json"
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

$apiApplicationIdUri = "api://$($app.appId)"
$scopeUri = "$apiApplicationIdUri/$scopeValue"

Invoke-Az 'Web app app settings' @(
    'webapp', 'config', 'appsettings', 'set',
    '--only-show-errors',
    '--resource-group', $resourceGroup,
    '--name', $webAppName,
    '--settings',
    "ENTRA_TENANT_ID=$tenantId",
    "ENTRA_CLIENT_ID=$($app.appId)",
    "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET=$($credential.password)",
    "MCP_WEATHER_KEY=$mcpWeatherKey",
    '--output', 'none'
)

Invoke-Az 'Web app obsolete app settings cleanup' @(
    'webapp', 'config', 'appsettings', 'delete',
    '--only-show-errors',
    '--resource-group', $resourceGroup,
    '--name', $webAppName,
    '--setting-names',
    'ENTRA_CLIENT_SECRET',
    'ENTRA_SCOPES',
    'SESSION_SECRET',
    '--output', 'none'
)

# Reapply Easy Auth on every postprovision run because infra\main.bicep provisions the
# app-service module with a placeholder empty Entra client ID before this hook repairs it.
Invoke-Az 'Web app Easy Auth provider' @(
    'webapp', 'auth', 'update',
    '--only-show-errors',
    '--resource-group', $resourceGroup,
    '--name', $webAppName,
    '--enabled', 'true',
    '--unauthenticated-client-action', 'AllowAnonymous',
    '--enable-token-store', 'true',
    '--set',
    'identityProviders.azureActiveDirectory.enabled=true',
    "identityProviders.azureActiveDirectory.registration.clientId=$($app.appId)",
    'identityProviders.azureActiveDirectory.registration.clientSecretSettingName=MICROSOFT_PROVIDER_AUTHENTICATION_SECRET',
    "identityProviders.azureActiveDirectory.registration.openIdIssuer=$entraIssuer",
    "identityProviders.azureActiveDirectory.login.loginParameters[0]=scope=openid profile email offline_access $scopeUri",
    # allowedAudiences restricts accepted aud claims for this API. allowedApplications
    # restricts which client application IDs may call it.
    "identityProviders.azureActiveDirectory.validation.allowedAudiences[0]=$($app.appId)",
    "identityProviders.azureActiveDirectory.validation.allowedAudiences[1]=$apiApplicationIdUri",
    "identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications[0]=$($app.appId)",
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

azd env set ENTRA_CLIENT_ID $app.appId --cwd $repoRoot | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Could not store the Entra client ID in the azd environment.'
}

Write-Host ''
Write-Host 'AI Observability Demo post-provision configuration completed.' -ForegroundColor Green
Write-Host "Web app:      $webAppUrl"
Write-Host "Model compare: $webAppUrl/model-comparison"
Write-Host "Code explain:  $webAppUrl/scientific-code-explainer"
Write-Host "FinOps hub:     $finOpsHubName (managed exports enabled)"
