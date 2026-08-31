[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

function Invoke-CheckedNative {
    param(
        [Parameter(Mandatory = $true)][string] $Command,
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [Parameter(Mandatory = $true)][string] $Description
    )

    Write-Host "Running $Description..."
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE."
    }
}

function Get-NamedStringValues {
    param(
        [AllowNull()] $Value,
        [Parameter(Mandatory = $true)][string] $PropertyName
    )

    if ($null -eq $Value) {
        return
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -eq $PropertyName -and $property.Value -is [string]) {
                Write-Output $property.Value
            }
            Get-NamedStringValues -Value $property.Value -PropertyName $PropertyName
        }
        return
    }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ($key -eq $PropertyName -and $Value[$key] -is [string]) {
                Write-Output $Value[$key]
            }
            Get-NamedStringValues -Value $Value[$key] -PropertyName $PropertyName
        }
        return
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) {
            Get-NamedStringValues -Value $item -PropertyName $PropertyName
        }
    }
}

function Test-DashboardContracts {
    $dashboardPath = Join-Path $repositoryRoot 'infra\dashboards\grafana-dashboard.json'
    $dashboardText = Get-Content -LiteralPath $dashboardPath -Raw
    $bundle = $dashboardText | ConvertFrom-Json -Depth 100

    Assert-True ($null -ne $bundle.business) 'The business Grafana dashboard is missing.'
    Assert-True ($null -ne $bundle.operations) 'The operations Grafana dashboard is missing.'

    $legacyTables = @(
        'AIObservabilityCostDaily_CL'
        'AIObservabilityFinOpsState_CL'
        'AIObservabilityResourceInventory_CL'
    )
    foreach ($table in $legacyTables) {
        Assert-True (-not $dashboardText.Contains($table)) "The dashboard still references the legacy table $table."
    }

    $queries = @(
        Get-NamedStringValues -Value $bundle -PropertyName 'query' |
            Where-Object {
                $_ -match '\b(AIRequestUsage_CL|AICostAllocation_CL|AzureMetrics|AzureActivity|AppTraces)\b'
            }
    )
    Assert-True ($queries.Count -gt 0) 'The Grafana dashboard contains no executable Azure queries.'

    $usageQueries = @($queries | Where-Object { $_ -match '\bAIRequestUsage_CL\b' })
    Assert-True ($usageQueries.Count -gt 0) 'The dashboard contains no usage queries.'
    foreach ($query in $usageQueries) {
        Assert-True (
            $query.Contains('ResourceGroupId =~ "__RESOURCE_GROUP_ID__"')
        ) 'A usage query does not apply the allowlisted resource-group predicate.'
        Assert-True (
            $query.Contains('ModelResourceId =~ "__FOUNDRY_RESOURCE_ID__"')
        ) 'A usage query does not apply the allowlisted model-resource predicate.'
    }

    $allocationQueries = @($queries | Where-Object { $_ -match '\bAICostAllocation_CL\b' })
    Assert-True ($allocationQueries.Count -gt 0) 'The dashboard contains no allocation queries.'
    foreach ($query in $allocationQueries) {
        $isWorkloadQuery = $query.Contains('SourceScope =~ "__RESOURCE_GROUP_ID__"')
        $isExternalQuery = (
            $query.Contains('SourceScope == "subscription"') -and
            $query.Contains('IncludedInWorkloadTotal == false')
        )
        Assert-True (
            $isWorkloadQuery -or $isExternalQuery
        ) 'An allocation query does not select an approved workload or external scope.'
        $calculatesWorkloadCost = (
            $query -match 'sum\((Allocated|Unallocated|Source)(Billed|Effective)?Cost'
        )
        if ($isWorkloadQuery -and $calculatesWorkloadCost) {
            Assert-True (
                $query.Contains('IncludedInWorkloadTotal == true')
            ) 'A workload allocation query can include external context rows.'
        }
    }
    Assert-True (
        @(
            $allocationQueries |
                Where-Object {
                    $_.Contains('SourceScope == "subscription"') -and
                    $_.Contains('IncludedInWorkloadTotal == false')
                }
        ).Count -gt 0
    ) 'The dashboard does not expose excluded subscription CCU context.'

    $resourceQueries = @(
        $queries |
            Where-Object { $_ -match '\b(AzureMetrics|AzureActivity)\b' }
    )
    foreach ($query in $resourceQueries) {
        Assert-True (
            $query -match '__[A-Z0-9_]+__'
        ) 'An Azure resource query does not contain a deployment substitution.'
    }

    $dashboardModulePath = Join-Path $repositoryRoot 'infra\modules\grafana-dashboard.bicep'
    $dashboardModule = Get-Content -LiteralPath $dashboardModulePath -Raw
    $dashboardResources = @(
        [regex]::Matches(
            $dashboardModule,
            "(?m)^\s*resource\s+\w+\s+'Microsoft\.Dashboard/dashboards@"
        )
    )
    $dashboardDefinitions = @(
        [regex]::Matches(
            $dashboardModule,
            "(?m)^\s*resource\s+\w+\s+'Microsoft\.Dashboard/dashboards/dashboardDefinitions@"
        )
    )
    Assert-True ($dashboardResources.Count -eq 2) 'The deployment must contain exactly two Grafana dashboard resources.'
    Assert-True ($dashboardDefinitions.Count -eq 2) 'Each Grafana dashboard must contain one dashboard definition.'

    Write-Host "Validated two Grafana dashboards and $($queries.Count) Azure queries."
}

function Test-TeardownContracts {
    $predown = Get-Content -LiteralPath (Join-Path $repositoryRoot 'hooks\predown.ps1') -Raw
    $postdown = Get-Content -LiteralPath (Join-Path $repositoryRoot 'hooks\postdown.ps1') -Raw
    $teardown = Get-Content -LiteralPath (Join-Path $repositoryRoot 'demo-scripts\teardown.ps1') -Raw

    foreach ($hook in @($predown, $postdown)) {
        Assert-True ($hook.Contains('FINOPS_RESOURCE_GROUP_NAME')) 'A teardown hook does not identify the sibling FinOps resource group.'
        Assert-True ($hook -match 'az\s+group\s+delete') 'A teardown hook does not delete the sibling FinOps resource group.'
        Assert-True ($hook -match 'az\s+role\s+assignment\s+delete') 'A teardown hook does not remove external role assignments.'
    }

    $combined = $predown + "`n" + $postdown + "`n" + $teardown
    foreach ($name in @(
        'FINOPS_DATA_FACTORY_COST_ROLE_ASSIGNMENT_ID'
        'USAGE_PROCESSOR_COST_ROLE_ASSIGNMENT_ID'
        'USAGE_PROCESSOR_FINOPS_STORAGE_ROLE_ASSIGNMENT_ID'
    )) {
        Assert-True ($combined.Contains($name)) "Teardown does not cover the external assignment $name."
    }
    Assert-True (
        $combined -notmatch 'az\s+keyvault\s+purge'
    ) 'Teardown must not purge the purge-protected Key Vault.'
    Assert-True (
        $combined -match 'purge protection|purge-protected'
    ) 'Teardown does not state the purge-protected Key Vault behavior.'

    Write-Host 'Validated teardown cleanup contracts.'
}

function Test-BicepBuild {
    $temporaryOutput = Join-Path $PSScriptRoot '.validation-main.json'
    try {
        $diagnostics = @(
            & az bicep build `
                --file (Join-Path $repositoryRoot 'infra\main.bicep') `
                --outfile $temporaryOutput 2>&1
        )
        $exitCode = $LASTEXITCODE
        foreach ($line in $diagnostics) {
            Write-Host $line
        }
        if ($exitCode -ne 0) {
            throw "Bicep build failed with exit code $exitCode."
        }

        $allowedWarnings = @(
            'infra[\\/]modules[\\/]apim-weather-mcp\.bicep.*Warning no-unnecessary-dependson'
            'infra[\\/]modules[\\/]api-center\.bicep.*Warning BCP187'
            'infra[\\/]modules[\\/]foundry\.bicep.*Warning BCP(036|037|416)'
        )
        $warnings = @($diagnostics | Where-Object { "$_" -match ':\s+Warning\s+' })
        foreach ($warning in $warnings) {
            $isAllowed = $false
            foreach ($pattern in $allowedWarnings) {
                if ("$warning" -match $pattern) {
                    $isAllowed = $true
                    break
                }
            }
            Assert-True $isAllowed "The Bicep build has a new warning: $warning"
        }
        Assert-True (
            Test-Path -LiteralPath $temporaryOutput -PathType Leaf
        ) 'The Bicep build did not create the compiled template.'
    }
    finally {
        Remove-Item -LiteralPath $temporaryOutput -Force -ErrorAction SilentlyContinue
    }

    Write-Host 'Validated the Bicep build and warning baseline.'
}

function Test-FunctionPackageContracts {
    $processorRoot = Join-Path $repositoryRoot 'src\usage-processor'
    foreach ($schemaName in @(
        'ai-usage-event.v1.json'
        'ai-cost-allocation.v1.json'
    )) {
        $repositorySchema = Join-Path $repositoryRoot "schemas\$schemaName"
        $packageSchema = Join-Path $processorRoot "schemas\$schemaName"
        Assert-True (
            Test-Path -LiteralPath $packageSchema -PathType Leaf
        ) "The Function package does not contain $schemaName."
        Assert-True (
            (Get-FileHash -LiteralPath $repositorySchema -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $packageSchema -Algorithm SHA256).Hash
        ) "The packaged $schemaName does not match the repository contract."
    }

    $processorModule = Get-Content -LiteralPath (
        Join-Path $repositoryRoot 'infra\modules\usage-processor.bicep'
    ) -Raw
    Assert-True (
        $processorModule.Contains('WORKLOAD_MODEL_RESOURCE_IDS')
    ) 'The Function App does not configure the model-resource allowlist.'
    Assert-True (
        $processorModule.Contains('LOG_ANALYTICS_WORKSPACE_ID')
    ) 'The Function App does not configure the Log Analytics workspace customer ID.'
    Assert-True (
        $processorModule.Contains('logAnalyticsWorkspace.properties.customerId')
    ) 'The Function App must use the Log Analytics workspace customer ID.'

    Write-Host 'Validated Function package contracts and allocation settings.'
}

Push-Location $repositoryRoot
try {
    & (Join-Path $PSScriptRoot 'verify-finops-release.ps1')
    & (Join-Path $PSScriptRoot 'test-apim-usage-policies.ps1')
    Test-DashboardContracts
    Test-TeardownContracts
    Test-BicepBuild
    Test-FunctionPackageContracts
    Invoke-CheckedNative `
        -Command 'python' `
        -Arguments @('-m', 'unittest', 'discover', '-s', '.\src\usage-processor\tests') `
        -Description 'Python usage processor tests'
    Invoke-CheckedNative `
        -Command 'npm.cmd' `
        -Arguments @('run', 'test:usage', '--prefix', '.\src\web') `
        -Description 'Node usage normalization tests'
}
finally {
    Pop-Location
}

Write-Host 'All deterministic token cost attribution checks passed.' -ForegroundColor Green
