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
        $preprovision.Contains("'Microsoft.DataFactory/factories/read'")
    ) 'The preprovision hook must require access to read an existing hub identity.'
    Assert-True (
        $preprovision.Contains("'Microsoft.DataFactory/factories/pipelines/createrun/action'") -and
        $preprovision.Contains("'Microsoft.DataFactory/factories/pipelineruns/read'")
    ) 'The preprovision hook must require access to initialize exports and monitor the configuration run.'
    Assert-True (
        -not $preprovision.Contains("'Microsoft.DataFactory/factories/*'")
    ) 'The preprovision hook must not use wildcard Data Factory permission checks.'
    foreach ($action in @('read', 'write', 'delete')) {
        Assert-True (
            $preprovision.Contains("'Microsoft.Resources/deploymentScripts/$action'")
        ) "Preprovision must require deployment-script $action access for FinOps trigger lifecycle handling."
    }
    Assert-True (
        $preprovision.Contains("'Microsoft.Web/sites/config/write'")
    ) 'The preprovision hook must keep the exact Web config write permission check for Easy Auth.'
    Assert-True (
        $preprovision.Contains("'Microsoft.Web/sites/functions/read'")
    ) 'The preprovision hook must require Microsoft.Web/sites/functions/read for the postdeploy function registration readiness check.'

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
    $mainBicep = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra\main.bicep') -Raw
    $mainParameters = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra\main.parameters.json') -Raw
    $apimBicep = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra\modules\apim.bicep') -Raw
    . (Join-Path $repositoryRoot 'hooks\app-auth.ps1')

    Assert-True (
        $postprovision.Contains('$webAppUrl/.auth/login/aad/callback') -and
        -not $postprovision.Contains('$webAppUrl/auth/callback')
    ) 'The postprovision hook must use the Easy Auth redirect URI.'
    Assert-True (
        $postprovision.Contains("'--enable-id-token-issuance', 'true'")
    ) 'The Entra application must enable ID token issuance for the Easy Auth response_type.'
    Assert-True (
        $postprovision.Contains("Write-Host 'Configuring App Service authentication' -ForegroundColor Cyan")
    ) 'The postprovision hook must label the Easy Auth configuration step clearly.'
    Assert-True (
        $postprovision.Contains("Invoke-AzText 'Azure cloud Active Directory endpoint'") -and
        $postprovision.Contains('$entraIssuer = ''{0}/{1}/v2.0'' -f $entraLoginEndpoint.TrimEnd(''/''), $tenantId')
    ) 'The postprovision hook must derive the OpenID issuer from the active Azure cloud.'
    Assert-True (
        $postprovision.Contains('config/authsettingsV2') -and
        $postprovision.Contains("'rest', '--method', 'PUT'") -and
        $postprovision.Contains('Set-AppServiceAuthProperties -CurrentProperties')
    ) 'The postprovision hook must update Easy Auth atomically through ARM.'
    Assert-True (
        $postprovision.Contains("[ValidateSet('All', 'Authentication')][string] `$Stage = 'All'") -and
        $postprovision.Replace("`r", '').Contains("if (`$Stage -eq 'All') {`n    & (Join-Path `$PSScriptRoot 'deploy-finops-hub.ps1')")
    ) 'The default stage must include FinOps; authentication-only resumption must be explicit.'

    $credentialResetIndex = $postprovision.IndexOf('$credential = Invoke-AzJson ''Entra app credential'' @(')
    $authUpdateIndex = $postprovision.IndexOf('Invoke-Az ''Web app Easy Auth provider'' @(')
    Assert-True (
        $credentialResetIndex -ge 0 -and $authUpdateIndex -gt $credentialResetIndex
    ) 'The postprovision hook must reapply Easy Auth after registration handling on every postprovision run.'
    $id = '00000000-0000-0000-0000-000000000001'
    $issuer = 'https://login.microsoftonline.com/00000000-0000-0000-0000-000000000002/v2.0'
    $properties = @{
        platform = @{ enabled = $false; runtimeVersion = '~1' }
        globalValidation = @{ requireAuthentication = $false }
        login = @{ tokenStore = @{ enabled = $false }; preserveUrlFragmentsForLogins = $true }
        identityProviders = @{
            azureActiveDirectory = @{
                enabled = $false
                validation = @{
                    defaultAuthorizationPolicy = @{ allowedPrincipals = @{ groups = @('existing-group') } }
                }
            }
            customProvider = @{ enabled = $false }
        }
        httpSettings = @{ forwardProxy = @{ convention = 'Standard' } }
    }
    $configured = Set-AppServiceAuthProperties -CurrentProperties $properties -ClientId $id -Issuer $issuer -ScopeUri "api://$id/access_as_user"
    $aad = $configured.identityProviders.azureActiveDirectory
    Assert-True ($configured.platform.enabled -and $aad.enabled -and $configured.login.tokenStore.enabled) 'Easy Auth, the Entra provider, and the token store must be enabled.'
    Assert-True ($aad.registration.clientId -ceq $id -and $aad.registration.openIdIssuer -ceq $issuer) 'The actual Entra client ID and HTTPS issuer must be applied.'
    Assert-True ($aad.registration.clientSecretSettingName -ceq 'MICROSOFT_PROVIDER_AUTHENTICATION_SECRET') 'The provider must reference the existing secret setting without embedding a credential.'
    Assert-True ($aad.login.loginParameters[0] -ceq "scope=openid profile email offline_access api://$id/access_as_user") 'The provider must request the delegated API scope.'
    Assert-True (@($aad.validation.allowedAudiences).Count -eq 2 -and $aad.validation.allowedAudiences[0] -ceq $id -and $aad.validation.allowedAudiences[1] -ceq "api://$id") 'Both supported API audiences must remain explicit.'
    Assert-True (@($aad.validation.defaultAuthorizationPolicy.allowedApplications).Count -eq 1 -and $aad.validation.defaultAuthorizationPolicy.allowedApplications[0] -ceq $id) 'The calling-client restriction must remain explicit.'
    Assert-True ($aad.validation.defaultAuthorizationPolicy.allowedPrincipals.groups[0] -ceq 'existing-group') 'Existing Entra principal restrictions must not be removed.'
    Assert-True ($configured.httpSettings.requireHttps -and $configured.httpSettings.forwardProxy.convention -ceq 'Standard') 'HTTPS must be required without losing the existing proxy configuration.'
    Assert-True ($configured.platform.runtimeVersion -ceq '~1' -and $configured.login.preserveUrlFragmentsForLogins -and $configured.identityProviders.ContainsKey('customProvider')) 'Unrelated platform, login, and provider settings must be preserved.'
    Assert-True (-not $configured.globalValidation.requireAuthentication -and $configured.globalValidation.unauthenticatedClientAction -ceq 'AllowAnonymous') 'The public health route and application-enforced route authorization must remain supported.'
    $failed = $false
    try { Set-AppServiceAuthProperties -CurrentProperties @{} -ClientId $id -Issuer $issuer -ScopeUri "api://$id/access_as_user" | Out-Null } catch { $failed = $true }
    Assert-True $failed 'Malformed current authentication settings must stop the update.'
    $failed = $false
    try { Set-AppServiceAuthProperties -CurrentProperties $properties -ClientId $id -Issuer 'http://example.invalid' -ScopeUri "api://$id/access_as_user" | Out-Null } catch { $failed = $true }
    Assert-True $failed 'An insecure issuer must be rejected before updating authentication.'
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
        $postprovision.Contains('api = @{') -and
        $postprovision.Contains('requestedAccessTokenVersion = 2')
    ) 'The postprovision hook must set api.requestedAccessTokenVersion to 2 in the Graph app patch payload.'
    Assert-True (
        $postprovision.Contains("'--named-value-id', 'entra-client-id'") -and
        $postprovision.Contains("'--value', `$app.appId")
    ) 'The postprovision hook must update the APIM Entra audience with the actual client ID.'
    Assert-True (
        $mainParameters.Contains('"entraClientId"') -and
        $mainParameters.Contains('${ENTRA_CLIENT_ID=}')
    ) 'The main parameter file must restore the persisted Entra client ID during later provisions.'
    Assert-True (
        $mainBicep.Contains("param entraClientId string = ''") -and
        ([regex]::Matches($mainBicep, 'entraClientId: entraClientId')).Count -eq 2
    ) 'The main template must pass one Entra client ID to APIM and App Service.'
    Assert-True (
        $apimBicep.Contains("param entraClientId string = ''") -and
        $apimBicep.Contains("empty(entraClientId) ? '00000000-0000-0000-0000-000000000000' : entraClientId")
    ) 'The APIM template must use the placeholder only before the first Entra registration exists.'

    Write-Host 'Validated postprovision Easy Auth integration contracts.'
}

function Test-BudgetPreservationContracts {
    $preprovision = Get-Content -LiteralPath (Join-Path $repositoryRoot 'hooks\preprovision.ps1') -Raw
    $mainParameters = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra\main.parameters.json') -Raw
    $deployFinOps = Get-Content -LiteralPath (Join-Path $repositoryRoot 'hooks\deploy-finops-hub.ps1') -Raw

    . (Join-Path $repositoryRoot 'hooks\budget-period.ps1')

    $budgetFixture = '{"startDate":"2031-08-01T00:00:00Z","endDate":"2041-08-01T00:00:00Z"}' | ConvertFrom-Json
    $previousCulture = [System.Threading.Thread]::CurrentThread.CurrentCulture
    try {
        foreach ($cultureName in @('en-US', 'en-GB', 'de-DE')) {
            [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::GetCultureInfo($cultureName)
            Assert-True ((ConvertTo-BudgetDate $budgetFixture.startDate) -ceq '2031-08-01') 'JSON budget dates must use an invariant date format.'
            Assert-True ((ConvertTo-BudgetDate $budgetFixture.endDate) -ceq '2041-08-01') 'Budget end dates must use an invariant date format.'
            Assert-True ((ConvertTo-BudgetDate '2031-08-01T00:00:00Z') -ceq '2031-08-01') 'String budget dates must remain supported.'
            Assert-True ((ConvertTo-BudgetDate ([DateTimeOffset]::Parse('2031-08-01T00:00:00Z'))) -ceq '2031-08-01') 'DateTimeOffset budget dates must remain supported.'
        }
    }
    finally {
        [System.Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture
    }

    # Preprovision must read and preserve the existing budget dates.
    Assert-True (
        $preprovision.Contains('BUDGET_START_DATE')
    ) 'The preprovision hook must set BUDGET_START_DATE in the azd environment.'
    Assert-True (
        $preprovision.Contains('BUDGET_END_DATE')
    ) 'The preprovision hook must set BUDGET_END_DATE in the azd environment.'
    Assert-True (
        $preprovision.Contains('Get-AzureBudgetPeriod') -and
        $preprovision.Contains("-BudgetName 'ai-observability-demo-monthly-budget'")
    ) 'The preprovision hook must resolve the main budget period from Azure.'
    Assert-True (
        @(($preprovision -split '\n') | Where-Object {
            $_ -match '20[0-9]{2}-[0-9]{2}-[0-9]{2}' -and $_ -notmatch '(?i)api[- ]?version'
        }).Count -eq 0
    ) 'The preprovision hook must not hardcode specific dates outside of api-version strings.'

    # main.parameters.json must reference both budget date env vars.
    Assert-True (
        $mainParameters.Contains('BUDGET_START_DATE')
    ) 'The main parameter file must reference BUDGET_START_DATE.'
    Assert-True (
        $mainParameters.Contains('BUDGET_END_DATE')
    ) 'The main parameter file must reference BUDGET_END_DATE.'

    # deploy-finops-hub.ps1 must forward the end date to the FinOps wrapper.
    Assert-True (
        $deployFinOps.Contains('Get-AzureBudgetPeriod') -and
        $deployFinOps.Contains('-ResourceGroupName $finOpsResourceGroupName -BudgetName "$finOpsHubName-support-budget"')
    ) 'The FinOps hook must resolve its own budget rather than inherit the main budget period.'

    $script:budgetResponse = '{"startDate":"2031-08-01T00:00:00Z","endDate":"2041-08-01T00:00:00Z"}'
    $script:budgetExitCode = 0
    function az {
        $global:LASTEXITCODE = $script:budgetExitCode
        $script:budgetResponse
    }
    $lookupArguments = @{
        SubscriptionId = '00000000-0000-0000-0000-000000000001'
        ResourceGroupName = 'rg-test'
        BudgetName = 'test-budget'
        Now = [DateTimeOffset]::Parse('2031-09-07T00:00:00Z')
    }
    $previousExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $previousExitCodeValue = if ($null -ne $previousExitCode) { $previousExitCode.Value } else { $null }
    try {
        $existing = Get-AzureBudgetPeriod @lookupArguments
        Assert-True ($existing.StartDate -ceq '2031-08-01' -and $existing.EndDate -ceq '2041-08-01') 'An existing budget must retain its period across a month boundary.'
        $script:budgetExitCode = 1
        $script:budgetResponse = 'ERROR: (NotFound) Budget not found.'
        $fresh = Get-AzureBudgetPeriod @lookupArguments
        Assert-True ($fresh.StartDate -ceq '2031-09-01' -and $fresh.EndDate -ceq '') 'A new support budget must start in its creation month without inheriting the main budget period.'
        $script:budgetResponse = 'ERROR: Not Found({"error":{"code":"404","message":"No matching budget."}})'
        $fresh = Get-AzureBudgetPeriod @lookupArguments
        Assert-True ($fresh.StartDate -ceq '2031-09-01' -and -not $fresh.Exists) 'The Cost Management structured 404 must initialize a new budget period.'
        foreach ($response in @('ERROR: (AuthorizationFailed) Access denied.', 'ERROR: (AuthorizationFailed) Reference contains (NotFound).', 'ERROR: (InternalServerError) Service unavailable.', '')) {
            $script:budgetResponse = $response
            $failed = $false
            try { Get-AzureBudgetPeriod @lookupArguments | Out-Null } catch { $failed = $true }
            Assert-True $failed 'A failed budget lookup must not select a new budget period.'
        }
        $script:budgetExitCode = 0
        $script:budgetResponse = '{}'
        $failed = $false
        try { Get-AzureBudgetPeriod @lookupArguments | Out-Null } catch { $failed = $true }
        Assert-True $failed 'A malformed existing budget must not select a new budget period.'
    }
    finally {
        if ($null -ne $previousExitCode) {
            Set-Variable -Name LASTEXITCODE -Scope Global -Value $previousExitCodeValue
        }
        else {
            Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name budgetResponse, budgetExitCode -Scope Script
    }

    Write-Host 'Validated budget start and end date preservation contracts.'
}

function Test-FinOpsTriggerScriptCache {
    . (Join-Path $repositoryRoot 'hooks\finops-script-cache.ps1')
    $subscriptionId = '00000000-0000-0000-0000-000000000001'
    $groupId = "/subscriptions/$subscriptionId/resourceGroups/rg-test-finops"
    $hubId = "$groupId/providers/Microsoft.Cloud/hubs/test-hub"
    $content = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra\vendor\finops-toolkit\v14\release\modules\fx\scripts\Init-DataFactory.ps1') -Raw
    $owned = @{
        name = 'Microsoft.FinOpsHubs.Core_ADF.StopTriggers'
        id = "$groupId/providers/Microsoft.Resources/deploymentScripts/Microsoft.FinOpsHubs.Core_ADF.StopTriggers"
        type = 'Microsoft.Resources/deploymentScripts'
        tags = @{ 'cm-resource-parent' = $hubId }
        scriptContent = $content
        provisioningState = 'Succeeded'
    }
    $foreign = $owned.Clone()
    $foreign.tags = @{ 'cm-resource-parent' = "$hubId-other" }
    $upload = $owned.Clone()
    $upload.scriptContent = 'Write-Output "Upload schema"'
    $arguments = @{ SubscriptionId = $subscriptionId; ResourceGroupName = 'rg-test-finops'; HubName = 'test-hub' }
    $script:cacheList = @($owned, $foreign, $upload)
    $script:cacheListExitCode = 0
    $script:cacheDeleteExitCode = 0
    $script:cacheDeletes = [System.Collections.Generic.List[string]]::new()
    $previousExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $previousExitCodeValue = if ($null -ne $previousExitCode) { $previousExitCode.Value } else { $null }
    function az {
        if ($args[0] -ne 'deployment-scripts') { throw 'Unexpected Azure command.' }
        if ($args[1] -eq 'list') {
            $global:LASTEXITCODE = $script:cacheListExitCode
            ConvertTo-Json -InputObject $script:cacheList -Depth 10
        }
        elseif ($args[1] -eq 'delete') {
            Assert-True ($args -contains '--yes') 'Cache cleanup must not prompt in noninteractive deployment hooks.'
            $global:LASTEXITCODE = $script:cacheDeleteExitCode
            $script:cacheDeletes.Add($args[[array]::IndexOf($args, '--name') + 1])
        }
        else { throw 'Unexpected deployment-script action.' }
    }
    try {
        Clear-FinOpsTriggerScriptCache @arguments
        Assert-True ($script:cacheDeletes.Count -eq 1 -and $script:cacheDeletes[0] -ceq $owned.name) 'Only the exact owned upstream trigger script record may be cleared.'
        $script:cacheList = @()
        Clear-FinOpsTriggerScriptCache @arguments
        Assert-True ($script:cacheDeletes.Count -eq 1) 'A first deployment must not delete any script records.'
        foreach ($state in @('Running', 'Failed', 'Canceled')) {
            $blocked = $owned.Clone()
            $blocked.provisioningState = $state
            $script:cacheList = @($owned, $blocked)
            $failed = $false
            try { Clear-FinOpsTriggerScriptCache @arguments } catch { $failed = $true }
            Assert-True ($failed -and $script:cacheDeletes.Count -eq 1) 'Non-successful scripts must retain their logs and prevent any cache deletion.'
        }
        $outside = $owned.Clone()
        $outside.id = '/subscriptions/other/resourceGroups/other/providers/Microsoft.Resources/deploymentScripts/other'
        $script:cacheList = @($outside)
        $failed = $false
        try { Clear-FinOpsTriggerScriptCache @arguments } catch { $failed = $true }
        Assert-True ($failed -and $script:cacheDeletes.Count -eq 1) 'A script with an unexpected resource ID must not be deleted.'
        foreach ($response in @(@{}, $null)) {
            $script:cacheList = $response
            $failed = $false
            try { Clear-FinOpsTriggerScriptCache @arguments } catch { $failed = $true }
            Assert-True $failed 'Malformed script listings must stop deployment.'
        }
        $script:cacheList = @($owned)
        $script:cacheListExitCode = 1
        $failed = $false
        try { Clear-FinOpsTriggerScriptCache @arguments } catch { $failed = $true }
        Assert-True ($failed -and $script:cacheDeletes.Count -eq 1) 'Listing failures must stop before deleting script records.'
        $script:cacheListExitCode = 0
        $script:cacheDeleteExitCode = 1
        $failed = $false
        try { Clear-FinOpsTriggerScriptCache @arguments } catch { $failed = $true }
        Assert-True $failed 'A failed cache deletion must stop deployment.'
    }
    finally {
        if ($null -ne $previousExitCode) {
            Set-Variable -Name LASTEXITCODE -Scope Global -Value $previousExitCodeValue
        }
        else {
            Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name cacheList, cacheListExitCode, cacheDeleteExitCode, cacheDeletes -Scope Script
    }
    $hook = Get-Content -LiteralPath (Join-Path $repositoryRoot 'hooks\deploy-finops-hub.ps1') -Raw
    Assert-True (
        $hook.IndexOf('Clear-FinOpsTriggerScriptCache -SubscriptionId') -lt $hook.IndexOf('az deployment group create') -and
        $hook.IndexOf('Clear-FinOpsTriggerScriptCache -SubscriptionId') -gt $hook.IndexOf('function Invoke-FinOpsDeployment')
    ) 'Both FinOps deployment passes must clear cached trigger scripts before deployment.'
    Write-Host 'Validated scoped FinOps trigger script cache handling.'
}

function Test-FinOpsUtcSchedules {
    . (Join-Path $repositoryRoot 'hooks\finops-template.ps1')
    $path = Join-Path $env:TEMP "aiobs-finops-template-$PID.json"
    $definitions = @(
        foreach ($start in @('2023-01-01T01:01:00', '2023-01-01T01:01:00', '2023-01-05T01:11:00')) {
            @{
                type = 'Microsoft.DataFactory/factories/triggers'
                properties = @{
                    type = 'ScheduleTrigger'
                    typeProperties = @{
                        recurrence = @{
                            startTime = $start
                            timeZone = "[reference('timeZones').outputs.Timezone.value]"
                            interval = 1
                        }
                    }
                }
            }
        }
    )
    $fixture = @{
        resources = @{
            nested = @{
                type = 'Microsoft.Resources/deployments'
                properties = @{ template = @{ resources = $definitions } }
            }
        }
        metadata = @{ unchangedDate = '2024-02-03T04:05:06Z' }
    }
    $original = ConvertTo-Json -InputObject $fixture -Depth 20
    try {
        Set-Content -LiteralPath $path -Value $original -Encoding utf8NoBOM
        Update-FinOpsUtcSchedules -TemplateFile $path
        $updated = [System.Text.Json.Nodes.JsonNode]::Parse((Get-Content -LiteralPath $path -Raw))
        $schedules = @(Get-FinOpsScheduleResource $updated)
        foreach ($schedule in $schedules) {
            $recurrence = $schedule['properties']['typeProperties']['recurrence']
            $expression = $recurrence['startTime'].ToString()
            Assert-True ($expression -cmatch "^\[if\(equals\(reference\('timeZones'\)\.outputs\.Timezone\.value, 'UTC'\), '(?<date>2023-01-0[15]T01:[01]1:00)Z', '\k<date>'\)\]$") 'Only UTC schedules may receive a Z suffix; mapped local-time schedules must retain their original value.'
            Assert-True ($recurrence['timeZone'].ToString() -ceq "[reference('timeZones').outputs.Timezone.value]") 'The upstream time-zone lookup must remain unchanged.'
            Assert-True ($recurrence['interval'].ToString() -ceq '1') 'Schedule intervals must remain unchanged.'
        }
        Assert-True ($updated['metadata']['unchangedDate'].ToString() -ceq '2024-02-03T04:05:06Z') 'Unrelated date strings must survive JSON serialization unchanged.'
        $fixture.resources.nested.properties.template.resources = @($definitions[0])
        $invalid = ConvertTo-Json -InputObject $fixture -Depth 20
        Set-Content -LiteralPath $path -Value $invalid -Encoding utf8NoBOM
        $before = Get-Content -LiteralPath $path -Raw
        $failed = $false
        try { Update-FinOpsUtcSchedules -TemplateFile $path } catch { $failed = $true }
        Assert-True ($failed -and (Get-Content -LiteralPath $path -Raw) -ceq $before) 'A changed upstream schedule set must fail without writing the template.'
    }
    finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    $hook = Get-Content -LiteralPath (Join-Path $repositoryRoot 'hooks\deploy-finops-hub.ps1') -Raw
    Assert-True (
        $hook.IndexOf('Update-FinOpsUtcSchedules -TemplateFile') -gt $hook.IndexOf('& $bicepExecutable build') -and
        $hook.IndexOf('Update-FinOpsUtcSchedules -TemplateFile') -lt $hook.IndexOf('$foundationOutputs = Invoke-FinOpsDeployment')
    ) 'Both deployment passes must use the corrected compiled template.'
    Write-Host 'Validated conditional FinOps UTC schedules and template guards.'
}

function Test-FinOpsFoundationReuse {
    . (Join-Path $repositoryRoot 'hooks\finops-foundation.ps1')
    $subscriptionId = '00000000-0000-0000-0000-000000000001'
    $principalId = '00000000-0000-0000-0000-000000000002'
    $groupId = "/subscriptions/$subscriptionId/resourceGroups/rg-test-finops"
    $factory = @{
        name = 'test-factory'
        id = "$groupId/providers/Microsoft.DataFactory/factories/test-factory"
        tags = @{ 'cm-resource-parent' = "$groupId/providers/Microsoft.Cloud/hubs/test-hub" }
        identity = @{ principalId = $principalId }
    }
    $arguments = @{ SubscriptionId = $subscriptionId; ResourceGroupName = 'rg-test-finops'; HubName = 'test-hub' }
    $script:factoryResponse = @{ value = @($factory) }
    $script:factoryExitCode = 0
    $previousExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $previousExitCodeValue = if ($null -ne $previousExitCode) { $previousExitCode.Value } else { $null }
    function az {
        Assert-True ($args[0] -eq 'rest' -and $args -contains 'GET') 'Foundation discovery must be read-only.'
        $global:LASTEXITCODE = $script:factoryExitCode
        ConvertTo-Json -InputObject $script:factoryResponse -Depth 10
    }
    try {
        Assert-True ((Get-FinOpsDataFactoryPrincipalId @arguments) -ceq $principalId) 'Redeployment must reuse the existing hub-owned identity.'
        $script:factoryResponse = @{ value = @() }
        Assert-True ($null -eq (Get-FinOpsDataFactoryPrincipalId @arguments)) 'A new hub must request foundation provisioning.'
        $foreign = $factory.Clone()
        $foreign.tags = @{ 'cm-resource-parent' = 'other-hub' }
        $script:factoryResponse = @{ value = @($foreign) }
        Assert-True ($null -eq (Get-FinOpsDataFactoryPrincipalId @arguments)) 'A foreign Data Factory must not supply the hub identity.'
        $invalidIdentity = $factory.Clone()
        $invalidIdentity.identity = @{ principalId = 'invalid' }
        foreach ($response in @(
            @{ value = @($factory, $factory) }
            @{ value = @($invalidIdentity) }
            @{ value = @(); nextLink = 'https://management.azure.com/next' }
            @{}
        )) {
            $script:factoryResponse = $response
            $failed = $false
            try { Get-FinOpsDataFactoryPrincipalId @arguments | Out-Null } catch { $failed = $true }
            Assert-True $failed 'Ambiguous, malformed, or incomplete foundation discovery must stop deployment.'
        }
        $script:factoryExitCode = 1
        $script:factoryResponse = @{ value = @() }
        $failed = $false
        try { Get-FinOpsDataFactoryPrincipalId @arguments | Out-Null } catch { $failed = $true }
        Assert-True $failed 'An Azure lookup failure must not be treated as a missing foundation.'
    }
    finally {
        if ($null -ne $previousExitCode) {
            Set-Variable -Name LASTEXITCODE -Scope Global -Value $previousExitCodeValue
        }
        else {
            Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name factoryResponse, factoryExitCode -Scope Script
    }
    Write-Host 'Validated existing FinOps foundation discovery.'
}

function Test-FinOpsExportConfiguration {
    . (Join-Path $repositoryRoot 'hooks\finops-foundation.ps1')
    $runId = '00000000-0000-0000-0000-000000000003'
    $arguments = @{
        SubscriptionId = '00000000-0000-0000-0000-000000000001'
        ResourceGroupName = 'rg-test-finops'
        DataFactoryName = 'test-factory'
        MaxPollAttempts = 3
        PollIntervalSeconds = 0
    }
    $script:configStates = [System.Collections.Generic.Queue[string]]::new([string[]]@('Queued', 'InProgress', 'Succeeded'))
    $script:configExitCode = 0
    $previousExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $previousExitCodeValue = if ($null -ne $previousExitCode) { $previousExitCode.Value } else { $null }
    function az {
        $global:LASTEXITCODE = $script:configExitCode
        $uri = $args[[array]::IndexOf($args, '--uri') + 1]
        Assert-True ($uri.StartsWith('https://management.azure.com/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-test-finops/providers/Microsoft.DataFactory/factories/test-factory/')) 'Configuration calls must remain in the selected Data Factory.'
        if ($args -contains 'POST') {
            Assert-True ($uri.EndsWith('/pipelines/config_ConfigureExports/createRun?api-version=2018-06-01')) 'Deployment must invoke the Microsoft export configuration pipeline only.'
            return '{"runId":"00000000-0000-0000-0000-000000000003"}'
        }
        Assert-True ($args -contains 'GET' -and $uri.EndsWith('/pipelineruns/00000000-0000-0000-0000-000000000003?api-version=2018-06-01')) 'Polling must inspect the exact configuration run.'
        @{ status = $script:configStates.Dequeue(); message = 'test status' } | ConvertTo-Json -Compress
    }
    try {
        Assert-True ((Invoke-FinOpsExportConfiguration @arguments) -ceq $runId) 'Configuration must wait for the created pipeline run to succeed.'
        foreach ($status in @('Failed', 'Cancelled', 'Unknown')) {
            $script:configStates.Enqueue($status)
            $failed = $false
            try { Invoke-FinOpsExportConfiguration @arguments | Out-Null } catch { $failed = $true }
            Assert-True $failed 'Failed or unknown pipeline states must stop deployment.'
        }
        $script:configStates = [System.Collections.Generic.Queue[string]]::new([string[]]@('InProgress', 'InProgress', 'InProgress'))
        $failed = $false
        try { Invoke-FinOpsExportConfiguration @arguments | Out-Null } catch { $failed = $true }
        Assert-True $failed 'An unfinished configuration run must not be treated as success.'
        $script:configExitCode = 1
        $failed = $false
        try { Invoke-FinOpsExportConfiguration @arguments | Out-Null } catch { $failed = $true }
        Assert-True $failed 'Configuration API failures must stop deployment.'
    }
    finally {
        if ($null -ne $previousExitCode) {
            Set-Variable -Name LASTEXITCODE -Scope Global -Value $previousExitCodeValue
        }
        else {
            Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name configStates, configExitCode -Scope Script
    }
    $hook = Get-Content -LiteralPath (Join-Path $repositoryRoot 'hooks\deploy-finops-hub.ps1') -Raw
    Assert-True (
        $hook.IndexOf('$configurationRunId = Invoke-FinOpsExportConfiguration') -gt $hook.IndexOf('$managedOutputs = Invoke-FinOpsDeployment') -and
        $hook.IndexOf('$configurationRunId = Invoke-FinOpsExportConfiguration') -lt $hook.IndexOf('$resourceGroupExportsJson = @()')
    ) 'Export configuration must finish after hub deployment and before export discovery.'
    Write-Host 'Validated explicit Microsoft export configuration and run monitoring.'
}

function Test-LocalAzdContracts {
    $predown = Get-Content -LiteralPath (Join-Path $repositoryRoot 'hooks\predown.ps1') -Raw
    $postdown = Get-Content -LiteralPath (Join-Path $repositoryRoot 'hooks\postdown.ps1') -Raw
    $deployFinOps = Get-Content -LiteralPath (Join-Path $repositoryRoot 'hooks\deploy-finops-hub.ps1') -Raw
    $preprovision = Get-Content -LiteralPath (Join-Path $repositoryRoot 'hooks\preprovision.ps1') -Raw
    $exportAccess = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra\modules\finops-export-access.bicep') -Raw
    $finOpsWrapper = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra\modules\finops-hub-wrapper.bicep') -Raw

    Assert-True (
        $exportAccess.Contains("targetScope = 'resourceGroup'") -and
        $exportAccess.Contains('scope: hubStorage') -and
        $exportAccess.Contains('principalId: dataFactoryPrincipalId') -and
        $exportAccess.Contains('f58310d9-a9f6-439a-9e8d-f62e7b41a168')
    ) 'Export access administration must use the Data Factory identity and remain scoped to the hub storage account.'
    Assert-True (
        $finOpsWrapper.Contains("module exportStorageAccess 'finops-export-access.bicep'") -and
        $finOpsWrapper.Contains('storageAccountName: finOpsHub.outputs.storageAccountName') -and
        $finOpsWrapper.Contains('dataFactoryPrincipalId: finOpsHub.outputs.managedIdentityId')
    ) 'The FinOps wrapper must provision export-identity delegation for its own storage and Data Factory.'

    Assert-True (
        $predown.Contains('azd env get-values --cwd $repoRoot 2>$null')
    ) 'The predown hook must read the active azd environment from the repository root.'
    Assert-True (
        $postdown.Contains('azd env get-values --cwd $repoRoot 2>$null')
    ) 'The postdown hook must read the active azd environment from the repository root.'
    Assert-True (
        $deployFinOps.Contains("Join-Path `$env:USERPROFILE '.azure\bin\bicep.exe'")
    ) 'The FinOps deployment hook must use the Azure CLI Bicep executable path directly on Windows.'

    # Tag preservation: existing RG tags must survive az group create calls.
    # The FinOps hook reads tags before creating so env-level tags are not silently replaced.
    $finOpsGroupShowIdx = $deployFinOps.IndexOf('az group show')
    $finOpsGroupCreateIdx = $deployFinOps.IndexOf('az group create')
    Assert-True (
        $finOpsGroupShowIdx -ge 0 -and $finOpsGroupCreateIdx -gt $finOpsGroupShowIdx
    ) 'The FinOps deployment hook must read existing resource group tags before creating/updating the group.'
    Assert-True (
        -not $deployFinOps.Contains('SecurityControl')
    ) 'The FinOps deployment hook must not hardcode environment-specific security control tags.'
    Assert-True (
        $deployFinOps.Contains('Could not read existing FinOps resource group tags:') -and
        $deployFinOps.Contains('The FinOps resource group tag lookup returned an empty response.')
    ) 'A failed tag lookup must stop before creating or updating the FinOps resource group.'
    # KV recovery calls az group create without --tags so ARM preserves existing tags.
    $recoveryCreateIdx = $preprovision.IndexOf('az group create', $preprovision.IndexOf('Recovering purge-protected Key Vault'))
    $recoveryTagsIdx = $preprovision.IndexOf('--tags', $recoveryCreateIdx)
    $recoveryNextNewline = $preprovision.IndexOf("`n--only-show-errors", $recoveryCreateIdx)
    Assert-True (
        $recoveryCreateIdx -ge 0 -and ($recoveryTagsIdx -eq -1 -or ($recoveryNextNewline -ge 0 -and $recoveryTagsIdx -gt $recoveryNextNewline))
    ) 'The KV recovery az group create call must not pass --tags to avoid overwriting existing RG tags.'

    Write-Host 'Validated local azd, FinOps wrapper, and RG tag-preservation contracts.'
}

function Test-PostdeployFunctionReadinessContracts {
    $postdeploy = Get-Content -LiteralPath (Join-Path $repositoryRoot 'hooks\postdeploy.ps1') -Raw

    # Postdeploy must delegate to the shared helper, not duplicate the logic inline.
    Assert-True (
        $postdeploy.Contains(". (Join-Path `$PSScriptRoot 'function-readiness.ps1')")
    ) 'The postdeploy hook must dot-source the function-readiness helper.'
    Assert-True (
        $postdeploy.Contains('Invoke-FunctionAppReadinessCheck')
    ) 'The postdeploy hook must call Invoke-FunctionAppReadinessCheck from the helper.'

    # Must read subscription and resource group from azd env values; no hardcoded names.
    Assert-True (
        $postdeploy.Contains("Get-RequiredValue `$values 'AZURE_SUBSCRIPTION_ID'")
    ) 'The postdeploy readiness check must read AZURE_SUBSCRIPTION_ID from azd env values.'
    Assert-True (
        $postdeploy.Contains("Get-RequiredValue `$values 'AZURE_RESOURCE_GROUP'")
    ) 'The postdeploy readiness check must read AZURE_RESOURCE_GROUP from azd env values.'
    Assert-True (
        $postdeploy.Contains("Get-RequiredValue `$values 'USAGE_PROCESSOR_FUNCTION_NAME'")
    ) 'The postdeploy readiness check must identify the Function App by its USAGE_PROCESSOR_FUNCTION_NAME azd value.'

    # All four expected function names must be explicitly listed at the call site.
    foreach ($name in @('ProcessAIUsage', 'MonitorEventHubCheckpoints', 'AllocateFocusCost', 'RecordClaudeCcuContext')) {
        Assert-True (
            $postdeploy.Contains("'$name'")
        ) "The postdeploy readiness check must list expected function '$name'."
    }

    # Existing steps must still be present.
    Assert-True (
        $postdeploy.Contains('/healthz')
    ) 'The postdeploy hook must still include the web health check.'
    Assert-True (
        $postdeploy.Contains('configure-weather-agent.ps1')
    ) 'The postdeploy hook must still run weather agent configuration.'

    Write-Host 'Validated postdeploy function registration readiness contracts.'
}

function Test-FunctionReadinessBehavior {
    . (Join-Path $repositoryRoot 'hooks\function-readiness.ps1')

    $app      = 'myapp'
    $sub      = '00000000-0000-0000-0000-000000000001'
    $rg       = 'rg-test'
    $expected = @('FuncA', 'FuncB', 'FuncC', 'FuncD')

    # Helper: build a mock that always returns the same JSON and exit code.
    function New-MockList {
        param([string] $Json, [int] $ExitCode = 0)
        return [scriptblock]::Create("`$global:LASTEXITCODE = $ExitCode; return @('$Json')")
    }

    # 1. All four functions present with '<app>/' prefix — happy path.
    $result = Invoke-FunctionAppReadinessCheck `
        -FunctionAppName $app -SubscriptionId $sub -ResourceGroupName $rg `
        -ExpectedFunctions $expected -MaxAttempts 1 -DelaySeconds 0 `
        -GetFunctionList (New-MockList '["myapp/FuncA","myapp/FuncB","myapp/FuncC","myapp/FuncD"]')
    Assert-True (
        $result.Count -eq 4 -and ($result -contains 'FuncA') -and ($result -notcontains 'myapp/FuncA')
    ) 'The helper must normalize <app>/<function> envelope names and return the bare function names.'

    # 2. Missing function after all retries must throw with the missing name.
    $failed = $false; $errMsg = ''
    try {
        Invoke-FunctionAppReadinessCheck `
            -FunctionAppName $app -SubscriptionId $sub -ResourceGroupName $rg `
            -ExpectedFunctions $expected -MaxAttempts 1 -DelaySeconds 0 `
            -GetFunctionList (New-MockList '["myapp/FuncA","myapp/FuncB","myapp/FuncC"]')
    } catch { $failed = $true; $errMsg = $_.Exception.Message }
    Assert-True $failed 'Missing functions must cause a hard failure after all retries.'
    Assert-True ($errMsg -match 'Missing') 'The error message must identify missing functions.'
    Assert-True ($errMsg -match 'FuncD') 'The error message must name the specific missing function.'

    # 3. Unexpected function must throw with the unexpected name.
    $failed = $false; $errMsg = ''
    try {
        Invoke-FunctionAppReadinessCheck `
            -FunctionAppName $app -SubscriptionId $sub -ResourceGroupName $rg `
            -ExpectedFunctions $expected -MaxAttempts 1 -DelaySeconds 0 `
            -GetFunctionList (New-MockList '["myapp/FuncA","myapp/FuncB","myapp/FuncC","myapp/FuncD","myapp/FuncE"]')
    } catch { $failed = $true; $errMsg = $_.Exception.Message }
    Assert-True $failed 'An unexpected function must cause a hard failure.'
    Assert-True ($errMsg -match 'Unexpected') 'The error message must identify unexpected functions.'
    Assert-True ($errMsg -match 'FuncE') 'The error message must name the unexpected function.'

    # 4. CLI error must throw immediately without retrying.
    $global:_cliErrCalls = 0
    $mockCliError = {
        param($a, $s, $r)
        $global:_cliErrCalls++
        $global:LASTEXITCODE = 1
        return @()
    }
    $failed = $false
    try {
        Invoke-FunctionAppReadinessCheck `
            -FunctionAppName $app -SubscriptionId $sub -ResourceGroupName $rg `
            -ExpectedFunctions $expected -MaxAttempts 3 -DelaySeconds 0 `
            -GetFunctionList $mockCliError
    } catch { $failed = $true }
    Assert-True $failed 'A non-zero az exit code must cause a hard failure.'
    Assert-True ($global:_cliErrCalls -eq 1) 'A non-zero az exit code must throw immediately; the az call must not be retried.'
    Remove-Item 'Variable:global:_cliErrCalls' -ErrorAction SilentlyContinue

    # 5. Malformed JSON must cause a hard failure (ConvertFrom-Json throws).
    $failed = $false
    try {
        Invoke-FunctionAppReadinessCheck `
            -FunctionAppName $app -SubscriptionId $sub -ResourceGroupName $rg `
            -ExpectedFunctions $expected -MaxAttempts 1 -DelaySeconds 0 `
            -GetFunctionList (New-MockList 'not valid json at all')
    } catch { $failed = $true }
    Assert-True $failed 'Malformed JSON from az must cause a hard failure.'

    # 6. Polling: empty first attempt, all four on second — must succeed after one retry.
    $global:_pollCalls = 0
    $mockPolling = {
        param($a, $s, $r)
        $global:LASTEXITCODE = 0
        $global:_pollCalls++
        if ($global:_pollCalls -le 1) { return @('[]') }
        return @('["myapp/FuncA","myapp/FuncB","myapp/FuncC","myapp/FuncD"]')
    }
    $result = Invoke-FunctionAppReadinessCheck `
        -FunctionAppName $app -SubscriptionId $sub -ResourceGroupName $rg `
        -ExpectedFunctions $expected -MaxAttempts 3 -DelaySeconds 0 `
        -GetFunctionList $mockPolling
    Assert-True ($global:_pollCalls -eq 2) 'The helper must retry when functions are not yet registered and succeed on a later attempt.'
    Assert-True ($result.Count -eq 4) 'The helper must return all four names after a successful poll.'
    Remove-Item 'Variable:global:_pollCalls' -ErrorAction SilentlyContinue

    Write-Host 'Validated function readiness check behavioral contracts.'
}

Push-Location $repositoryRoot
try {
    Test-PowerShellSyntax @(
        'hooks\preprovision.ps1'
        'hooks\budget-period.ps1'
        'hooks\finops-script-cache.ps1'
        'hooks\finops-template.ps1'
        'hooks\finops-foundation.ps1'
        'hooks\deploy-finops-hub.ps1'
        'hooks\postprovision.ps1'
        'hooks\app-auth.ps1'
        'hooks\postdeploy.ps1'
        'hooks\function-readiness.ps1'
        'hooks\predown.ps1'
        'hooks\postdown.ps1'
        'demo-scripts\teardown.ps1'
    )
    Test-PreprovisionContracts
    Test-BudgetPreservationContracts
    Test-FinOpsTriggerScriptCache
    Test-FinOpsUtcSchedules
    Test-FinOpsFoundationReuse
    Test-FinOpsExportConfiguration
    Test-EntraCleanupContracts
    Test-TeardownInheritedApprovalRegression
    Test-PostprovisionAuthContracts
    Test-LocalAzdContracts
    Test-PostdeployFunctionReadinessContracts
    Test-FunctionReadinessBehavior
}
finally {
    Pop-Location
}

Write-Host 'Lifecycle hook checks passed.' -ForegroundColor Green
