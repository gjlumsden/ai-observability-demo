Set-StrictMode -Version Latest

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool] $Condition,
        [Parameter(Mandatory = $true)][string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Test-PowerShellSyntax {
    param(
        [Parameter(Mandatory = $true)][string[]] $RelativePaths
    )

    foreach ($relativePath in $RelativePaths) {
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $repositoryRoot $relativePath),
            [ref] $tokens,
            [ref] $errors
        ) | Out-Null
        Assert-True ($errors.Count -eq 0) "PowerShell syntax parsing failed for $relativePath."
    }
}

function Test-PreprovisionContracts {
    $preprovision = Get-Content -LiteralPath (Join-Path $repositoryRoot 'hooks\preprovision.ps1') -Raw

    Assert-True (
        -not $preprovision.Contains("'resource', 'delete'")
    ) 'The preprovision hook must not delete legacy resources automatically.'
    Assert-True (
        -not ($preprovision -match 'az\s+provider\s+register')
    ) 'The preprovision hook must not change provider registration.'
    Assert-True (
        $preprovision.Contains('The provider-registration and legacy-resource checks in this hook are read-only and will not change Azure state.')
    ) 'The preprovision hook must explain that only the provider and legacy checks are read-only.'
    Assert-True (
        $preprovision.Contains('Run .\demo-scripts\teardown.ps1 before the first redesign deployment.')
    ) 'The preprovision hook must direct operators to the approved teardown path.'
    Assert-True (
        $preprovision.Contains("'Microsoft.DataFactory/factories/write'")
    ) 'The preprovision hook must keep exact Data Factory permission checks.'
    Assert-True (
        -not $preprovision.Contains("'Microsoft.DataFactory/factories/*'")
    ) 'The preprovision hook must not use wildcard Data Factory permission checks.'

    Write-Host 'Validated preprovision legacy-check and permission contracts.'
}

function Test-EntraCleanupContracts {
    $postdown = Get-Content -LiteralPath (Join-Path $repositoryRoot 'hooks\postdown.ps1') -Raw
    $postprovision = Get-Content -LiteralPath (Join-Path $repositoryRoot 'hooks\postprovision.ps1') -Raw
    $teardown = Get-Content -LiteralPath (Join-Path $repositoryRoot 'demo-scripts\teardown.ps1') -Raw

    Assert-True (
        $postdown.Contains('AI_OBSERVABILITY_DELETE_ENTRA_APP')
    ) 'The postdown hook must require explicit Entra cleanup approval.'
    Assert-True (
        $postdown.Contains('Retaining Entra app registration')
    ) 'The postdown hook must keep the Entra app by default.'

    $approvedBranch = [System.Text.RegularExpressions.Regex]::Match(
        $postdown,
        'if \(\$deleteEntraApplication\) \{(?<body>.*?)\}\s*elseif \(\$clientId\) \{',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    ).Groups['body'].Value
    $retainedBranch = [System.Text.RegularExpressions.Regex]::Match(
        $postdown,
        'elseif \(\$clientId\) \{(?<body>.*?)\}\s*\$keyVaultName =',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    ).Groups['body'].Value
    Assert-True ([bool]$approvedBranch) 'The approved Entra cleanup branch is missing from postdown.'
    Assert-True ([bool]$retainedBranch) 'The default Entra retention branch is missing from postdown.'
    Assert-True (
        $approvedBranch.Contains('az ad app delete')
    ) 'The approved Entra cleanup branch must delete the app registration.'
    Assert-True (
        -not $retainedBranch.Contains('az ad app delete')
    ) 'The default postdown branch must not delete the Entra app registration.'

    Assert-True (
        $teardown.Contains('[switch] $DeleteEntraApplication')
    ) 'The teardown script must expose an explicit Entra cleanup switch.'
    Assert-True (
        $teardown.Contains('delete Entra app registration')
    ) 'The teardown script must require an Entra-specific confirmation.'
    Assert-True (
        $teardown.Contains('$env:AI_OBSERVABILITY_DELETE_ENTRA_APP = ''true''') -and
        $teardown.Contains('Remove-Item Env:\AI_OBSERVABILITY_DELETE_ENTRA_APP -ErrorAction SilentlyContinue')
    ) 'The teardown script must set the approval flag only after explicit approval and clear inherited values otherwise.'
    Assert-True (
        $teardown -match "azd env set ENTRA_CLIENT_ID '' --cwd [$]repoRoot"
    ) 'The teardown script must clear the deleted ENTRA_CLIENT_ID from the local azd environment.'
    Assert-True (
        $teardown.Contains('azd down deletes Azure resources only. It keeps the local .azure environment files.')
    ) 'The teardown script must document the current azd down local-environment behavior.'
    Assert-True (
        -not $teardown.Contains('azd env remove')
    ) 'The teardown script must not remove the local azd environment automatically.'

    Assert-True (
        $postprovision.Contains('function Get-OptionalEntraApplicationByClientId {')
    ) 'The postprovision hook must handle stale ENTRA_CLIENT_ID values.'
    Assert-True (
        $postprovision.Contains('does not resolve to an existing Entra app')
    ) 'The postprovision hook must explain stale ENTRA_CLIENT_ID recovery.'
    Assert-True (
        $postprovision.Contains('azd env set ENTRA_CLIENT_ID $app.appId --cwd $repoRoot')
    ) 'The postprovision hook must persist the repaired ENTRA_CLIENT_ID in the local azd environment.'

    Write-Host 'Validated approved and unapproved Entra cleanup contracts.'
}

function Test-TeardownInheritedApprovalRegression {
    $tempRoot = Join-Path $env:TEMP "aiobs-teardown-regression-$PID"
    $downEnvFile = Join-Path $tempRoot 'down-env.txt'
    $commandLog = Join-Path $tempRoot 'azd-log.txt'
    $mockAzdPath = Join-Path $tempRoot 'azd.cmd'
    $previousPath = $env:PATH
    $previousDeleteFlag = [Environment]::GetEnvironmentVariable('AI_OBSERVABILITY_DELETE_ENTRA_APP')

    try {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        Set-Content -LiteralPath $mockAzdPath -Encoding ascii -NoNewline -Value @"
@echo off
if "%1"=="env" (
  if "%2"=="get-values" (
    echo ENTRA_CLIENT_ID=test-client-id
    exit /b 0
  )
  if "%2"=="set" (
    >>"%~dp0azd-log.txt" echo env set %3 %4
    exit /b 0
  )
)
if "%1"=="down" (
  if defined AI_OBSERVABILITY_DELETE_ENTRA_APP (
    >"%~dp0down-env.txt" echo %AI_OBSERVABILITY_DELETE_ENTRA_APP%
  ) else (
    >"%~dp0down-env.txt" echo.
  )
  >>"%~dp0azd-log.txt" echo down %*
  exit /b 0
)
>>"%~dp0azd-log.txt" echo unexpected %*
exit /b 1
"@

        $env:PATH = "$tempRoot;$previousPath"
        $env:AI_OBSERVABILITY_DELETE_ENTRA_APP = 'true'
        $teardownScript = Join-Path $repositoryRoot 'demo-scripts\teardown.ps1'
        $output = @("delete ai observability demo", 'keep existing app') | & pwsh -NoProfile -File $teardownScript -DeleteEntraApplication 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Teardown regression run failed: $($output -join "`n")"
        }

        Assert-True (
            (Get-Content -LiteralPath $downEnvFile -Raw).Trim().Length -eq 0
        ) 'The teardown script must clear an inherited approval flag before azd down when Entra deletion is not approved.'
        Assert-True (
            ($output -join "`n").Contains('Entra app deletion was not approved. The app registration will be retained.')
        ) 'The teardown regression must exercise the denied Entra deletion path.'
        $commandText = if (Test-Path -LiteralPath $commandLog) { Get-Content -LiteralPath $commandLog -Raw } else { '' }
        Assert-True (
            -not $commandText.Contains('env set ENTRA_CLIENT_ID')
        ) 'The teardown script must not clear ENTRA_CLIENT_ID when Entra deletion is not approved.'
    }
    finally {
        $env:PATH = $previousPath
        if ($null -eq $previousDeleteFlag) {
            Remove-Item Env:\AI_OBSERVABILITY_DELETE_ENTRA_APP -ErrorAction SilentlyContinue
        }
        else {
            $env:AI_OBSERVABILITY_DELETE_ENTRA_APP = $previousDeleteFlag
        }
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Host 'Validated teardown inherited-approval regression behavior.'
}
function Test-PostprovisionAuthContracts {
    $postprovision = Get-Content -LiteralPath (Join-Path $repositoryRoot 'hooks\postprovision.ps1') -Raw

    Assert-True (
        $postprovision.Contains('$webAppUrl/.auth/login/aad/callback') -and
        -not $postprovision.Contains('$webAppUrl/auth/callback')
    ) 'The postprovision hook must use the Easy Auth redirect URI.'
    Assert-True (
        $postprovision.Contains("Write-Host 'Configuring App Service authentication' -ForegroundColor Cyan")
    ) 'The postprovision hook must label the Easy Auth configuration step clearly.'
    Assert-True (
        $postprovision.Contains("Invoke-AzText 'Azure cloud Active Directory endpoint'") -and
        $postprovision.Contains('$entraIssuer = ''{0}/{1}/v2.0'' -f $entraLoginEndpoint.TrimEnd(''/''), $tenantId')
    ) 'The postprovision hook must derive the OpenID issuer from the active Azure cloud.'
    Assert-True (
        $postprovision.Contains("'webapp', 'auth', 'update'")
    ) 'The postprovision hook must finalize Easy Auth with az webapp auth update.'

    $credentialResetIndex = $postprovision.IndexOf('$credential = Invoke-AzJson ''Entra app credential'' @(')
    $authUpdateIndex = $postprovision.IndexOf('Invoke-Az ''Web app Easy Auth provider'' @(')
    Assert-True (
        $credentialResetIndex -ge 0 -and $authUpdateIndex -gt $credentialResetIndex
    ) 'The postprovision hook must reapply Easy Auth after registration handling on every postprovision run.'
    foreach ($setting in @(
        'identityProviders.azureActiveDirectory.enabled=true'
        'identityProviders.azureActiveDirectory.registration.clientId=$($app.appId)'
        'identityProviders.azureActiveDirectory.registration.clientSecretSettingName=MICROSOFT_PROVIDER_AUTHENTICATION_SECRET'
        'identityProviders.azureActiveDirectory.registration.openIdIssuer=$entraIssuer'
        'identityProviders.azureActiveDirectory.login.loginParameters[0]=scope=openid profile email offline_access $scopeUri'
        'identityProviders.azureActiveDirectory.validation.allowedAudiences[0]=$($app.appId)'
        'identityProviders.azureActiveDirectory.validation.allowedAudiences[1]=$apiApplicationIdUri'
        'identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications[0]=$($app.appId)'
    )) {
        Assert-True (
            $postprovision.Contains($setting)
        ) "The postprovision hook must set $setting in the Easy Auth provider update."
    }
    Assert-True (
        $postprovision.Contains('MICROSOFT_PROVIDER_AUTHENTICATION_SECRET=$($credential.password)')
    ) 'The postprovision hook must store the Easy Auth client secret in MICROSOFT_PROVIDER_AUTHENTICATION_SECRET.'
    Assert-True (
        $postprovision.Contains("'webapp', 'config', 'appsettings', 'delete'") -and
        $postprovision.Contains("'ENTRA_CLIENT_SECRET'") -and
        $postprovision.Contains("'ENTRA_SCOPES'") -and
        $postprovision.Contains("'SESSION_SECRET'")
    ) 'The postprovision hook must remove obsolete web app settings.'
    Assert-True (
        -not $postprovision.Contains('ENTRA_CLIENT_SECRET=$($credential.password)') -and
        -not $postprovision.Contains('ENTRA_SCOPES=api://$($app.appId)/$scopeValue') -and
        -not $postprovision.Contains('SESSION_SECRET=$sessionSecret')
    ) 'The postprovision hook must not keep obsolete MSAL/session app settings.'
    Assert-True (
        $postprovision.Contains('identityProviders.azureActiveDirectory.validation.allowedAudiences[0]=$($app.appId)') -and
        $postprovision.Contains('identityProviders.azureActiveDirectory.validation.allowedAudiences[1]=$apiApplicationIdUri')
    ) 'The postprovision hook must validate token audiences explicitly with both the API client ID and App ID URI.'
    Assert-True (
        $postprovision.Contains('identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedApplications[0]=$($app.appId)')
    ) 'The postprovision hook must restrict allowedApplications to the configured client application identity explicitly.'
    Assert-True (
        $postprovision.Contains('api = @{') -and
        $postprovision.Contains('requestedAccessTokenVersion = 2')
    ) 'The postprovision hook must set api.requestedAccessTokenVersion to 2 in the Graph app patch payload.'

    Write-Host 'Validated postprovision Easy Auth integration contracts.'
}

function Test-LocalAzdContracts {
    $predown = Get-Content -LiteralPath (Join-Path $repositoryRoot 'hooks\predown.ps1') -Raw
    $postdown = Get-Content -LiteralPath (Join-Path $repositoryRoot 'hooks\postdown.ps1') -Raw
    $deployFinOps = Get-Content -LiteralPath (Join-Path $repositoryRoot 'hooks\deploy-finops-hub.ps1') -Raw

    Assert-True (
        $predown.Contains('azd env get-values --cwd $repoRoot 2>$null')
    ) 'The predown hook must read the active azd environment from the repository root.'
    Assert-True (
        $postdown.Contains('azd env get-values --cwd $repoRoot 2>$null')
    ) 'The postdown hook must read the active azd environment from the repository root.'
    Assert-True (
        $deployFinOps.Contains("Join-Path `$env:USERPROFILE '.azure\bin\bicep.exe'")
    ) 'The FinOps deployment hook must use the Azure CLI Bicep executable path directly on Windows.'

    Write-Host 'Validated local azd and FinOps wrapper contracts.'
}

Push-Location $repositoryRoot
try {
    Test-PowerShellSyntax @(
        'hooks\preprovision.ps1'
        'hooks\postprovision.ps1'
        'hooks\predown.ps1'
        'hooks\postdown.ps1'
        'demo-scripts\teardown.ps1'
    )
    Test-PreprovisionContracts
    Test-EntraCleanupContracts
    Test-TeardownInheritedApprovalRegression
    Test-PostprovisionAuthContracts
    Test-LocalAzdContracts
}
finally {
    Pop-Location
}

Write-Host 'Lifecycle hook checks passed.' -ForegroundColor Green
