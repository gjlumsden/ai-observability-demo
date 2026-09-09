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

function Resolve-BicepExecutable {
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($env:BICEP_CLI_PATH) {
        $candidates.Add($env:BICEP_CLI_PATH)
    }

    $pathCommand = Get-Command bicep -CommandType Application -ErrorAction SilentlyContinue
    if ($null -ne $pathCommand -and $pathCommand.Source) {
        $candidates.Add($pathCommand.Source)
    }

    $candidates.Add((Join-Path $HOME '.azure\bin\bicep.exe'))

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw 'The Bicep CLI executable is not available. Set BICEP_CLI_PATH.'
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
        Assert-True (
            $query.Contains('RecordType == "allocation"') -and
            $query.Contains('RecordType == "run-complete"') -and
            $query.Contains('summarize arg_max(TimeGenerated, *) by RunId, RecordId') -and
            $query.Contains('ActualRecordCount = count()') -and
            $query.Contains('ActualRecordCount == ExpectedRecordCount')
        ) 'An allocation query does not require a verified complete run.'
        $calculatesWorkloadCost = (
            $query -match 'sum\((Allocated|Unallocated|Source)(Billed|Effective)?Cost'
        )
        if ($isWorkloadQuery -and $calculatesWorkloadCost) {
            Assert-True (
                $query.Contains('IncludedInWorkloadTotal == true')
            ) 'A workload allocation query can include external context rows.'
        }
        if ($calculatesWorkloadCost) {
            Assert-True (
                $query.Contains('IncludedInWorkloadTotal == true') -or
                $isExternalQuery
            ) 'An allocation total can mix workload and external context.'
        }
        if ($query.Contains('let AllocationLastSeen')) {
            Assert-True (
                $query.Contains('SourceType == "finops-hub-focus-v1.2-preview"') -and
                $query.Contains('SourceScope =~ "__RESOURCE_GROUP_ID__"')
            ) 'Workload allocation freshness can include a non-FOCUS or external run.'
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
    Assert-True (
        -not $dashboardText.Contains('Needs checkpoint instrumentation')
    ) 'The operations dashboard still contains the checkpoint placeholder.'
    Assert-True (
        -not $dashboardText.Contains('Needs separate instrumentation')
    ) 'The duplicate and replay tile still contains placeholder status text.'
    Assert-True (
        -not $dashboardText.Contains('tolong(null)')
    ) 'A dashboard query uses invalid KQL null conversion syntax.'
    $invalidNullAggregateQueries = @(
        $queries |
            Where-Object {
                $_ -match '(?m)^\| summarize[^\r\n]*=\s*(?:to)?(?:real|long)\(null\)'
            }
    )
    Assert-True (
        $invalidNullAggregateQueries.Count -eq 0
    ) 'A dashboard query uses a scalar null expression as a summarize aggregate.'
    Assert-True (
        @(
            [regex]::Matches(
                $dashboardText,
                'project RunId, CompletionTime = TimeGenerated, SourceType, SourceScope, SourcePath;'
            )
        ).Count -eq 4
    ) 'Allocation freshness queries discard fields required by later filters.'
    Assert-True (
        $dashboardText.Contains('todouble(datetime_diff(\"hour\", now(), LastCompletedRun))') -and
        $dashboardText.Contains('todouble(datetime_diff(\"hour\", now(), LastSeen))')
    ) 'Allocation age queries do not return a type compatible with their null branch.'
    Assert-True (
        $dashboardText.Contains('UsageProcessorCheckpointStatus') -and
        $dashboardText.Contains('checkpointAgeSeconds') -and
        $dashboardText.Contains('sequenceLag') -and
        $dashboardText.Contains('LastEnqueuedSequenceNumber < 0, long(null), EventAgeSeconds')
    ) 'The operations dashboard does not query valid checkpoint telemetry.'
    Assert-True (
        -not $dashboardText.Contains('UsageLastSeen < ago(30m)') -and
        -not $dashboardText.Contains('AllocationLastSeen < ago(36h)')
    ) 'A business summary overrides the selected dashboard period with a fixed freshness gate.'
    Assert-True (
        $dashboardText.Contains('Category = strcat(Provider, \" / Uncached input\")') -and
        $dashboardText.Contains('| order by Category asc')
    ) 'The provider token chart does not produce unique provider and token-category labels.'
    Assert-True (
        $dashboardText.Contains('ProblemId has \"WorkerProcess.ThrowIfExitError\"') -and
        $dashboardText.Contains('OuterMessage has \"exited with code 143\"')
    ) 'The function failure query does not exclude normal worker recycling.'
    Assert-True (
        -not $dashboardText.Contains('\"dimensionFilters\"')
    ) 'A dashboard metric target filters on a dimension unavailable in its Azure metric definition.'
    $metricTargets = @(
        $bundle.operations.panels |
            ForEach-Object {
                if ($_.PSObject.Properties['targets']) {
                    $_.targets
                }
            } |
            Where-Object { $_.queryType -eq 'Azure Monitor' }
    )
    Assert-True ($metricTargets.Count -eq 6) 'The operations dashboard metric target count changed unexpectedly.'
    foreach ($target in $metricTargets) {
        Assert-True (
            $target.subscription -eq '__SUBSCRIPTION_ID__'
        ) 'An Azure Monitor metric target does not define the subscription at the target level.'
        Assert-True (
            $target.azureMonitor.metricDefinition -eq $target.azureMonitor.metricNamespace
        ) 'An Azure Monitor metric target does not define its metric resource type.'
        $resourceProperties = @($target.azureMonitor.resources[0].PSObject.Properties.Name)
        Assert-True (
            $resourceProperties.Count -eq 2 -and
            $resourceProperties -contains 'resourceGroup' -and
            $resourceProperties -contains 'resourceName'
        ) 'An Azure Monitor metric resource contains fields that Grafana interprets as a malformed resource ID.'
    }
    Assert-True (
        $dashboardText.Contains('ReconciliationResidual = sum(Residual) by TimeGenerated = bin(ChargePeriodStart, 1d)')
    ) 'The reconciliation residual query does not return a Grafana time axis.'
    Assert-True (
        $dashboardText.Contains('case(TokenQuality in (\"missing\", \"interrupted\", \"unavailable\"), strcat(\"token quality: \", TokenQuality), isempty(RateCardVersionId)')
    ) 'The dashboard must report missing token evidence before it reports a missing rate.'

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

function Test-WorkbookContracts {
    $workbookPath = Join-Path $repositoryRoot 'infra\workbooks\monitoring-workbook.json'
    $workbookText = Get-Content -LiteralPath $workbookPath -Raw
    $workbook = $workbookText | ConvertFrom-Json -Depth 100
    $queries = @(
        Get-NamedStringValues -Value $workbook -PropertyName 'query' |
            Where-Object {
                $_ -match '\b(AIRequestUsage_CL|AICostAllocation_CL|AppTraces)\b'
            }
    )

    Assert-True (
        $workbookText.Contains('UsageProcessorCheckpointStatus') -and
        $workbookText.Contains('checkpointAgeSeconds')
    ) 'The investigation workbook does not expose checkpoint telemetry.'
    Assert-True (
        $workbookText.Contains("case(TokenQuality in ('missing', 'interrupted', 'unavailable'), strcat('token quality: ', TokenQuality), isempty(RateCardVersionId)")
    ) 'The workbook must report missing token evidence before it reports a missing rate.'
    foreach ($query in @($queries | Where-Object { $_ -match '\bAICostAllocation_CL\b' })) {
        Assert-True (
            $query.Contains("RecordType == 'allocation'") -and
            $query.Contains("RecordType == 'run-complete'") -and
            $query.Contains('summarize arg_max(TimeGenerated, *) by RunId, RecordId') -and
            $query.Contains('ActualRecordCount = count()') -and
            $query.Contains('ActualRecordCount == ExpectedRecordCount')
        ) 'A workbook allocation query does not require a verified complete run.'
        $calculatesAllocationTotal = (
            $query -match 'sum\((Allocated|Unallocated|Source)(Billed|Effective)?Cost'
        )
        if ($calculatesAllocationTotal) {
            Assert-True (
                $query.Contains("RecordType == 'run-complete'") -and
                $query.Contains('ActualRecordCount = count()') -and
                $query.Contains('ActualRecordCount == ExpectedRecordCount')
            ) 'A workbook allocation total can include a partial or replayed run.'
        }
    }

    Write-Host "Validated the investigation workbook and $($queries.Count) queries."
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
    $bicep = Resolve-BicepExecutable
    $mainOutput = Join-Path $PSScriptRoot '.validation-main.json'
    $finOpsOutput = Join-Path $PSScriptRoot '.validation-finops.json'
    try {
        $diagnostics = @(
            & $bicep build `
                (Join-Path $repositoryRoot 'infra\main.bicep') `
                --outfile $mainOutput 2>&1
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
            Test-Path -LiteralPath $mainOutput -PathType Leaf
        ) 'The Bicep build did not create the compiled template.'

        $finOpsDiagnostics = @(
            & $bicep build `
                (Join-Path $repositoryRoot 'infra\modules\finops-hub-wrapper.bicep') `
                --outfile $finOpsOutput 2>&1
        )
        $finOpsExitCode = $LASTEXITCODE
        foreach ($line in $finOpsDiagnostics) {
            Write-Host $line
        }
        if ($finOpsExitCode -ne 0) {
            throw "The FinOps wrapper Bicep build failed with exit code $finOpsExitCode."
        }
        Assert-True (
            Test-Path -LiteralPath $finOpsOutput -PathType Leaf
        ) 'The FinOps wrapper build did not create the compiled template.'
    }
    finally {
        Remove-Item -LiteralPath $mainOutput -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $finOpsOutput -Force -ErrorAction SilentlyContinue
    }

    Write-Host 'Validated the main and FinOps wrapper Bicep builds and warning baseline.'
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
    $requirements = Get-Content -LiteralPath (
        Join-Path $processorRoot 'requirements.txt'
    ) -Raw
    Assert-True (
        $requirements.Contains('azure-eventhub==5.15.1')
    ) 'The Function package does not pin the Event Hubs SDK used by the checkpoint monitor.'
    $functionApp = Get-Content -LiteralPath (
        Join-Path $processorRoot 'function_app.py'
    ) -Raw
    Assert-True (
        $functionApp.Contains('name="MonitorEventHubCheckpoints"') -and
        $functionApp.Contains('run_checkpoint_monitor()')
    ) 'The periodic checkpoint monitor Function is not registered.'
    $hostConfiguration = Get-Content -LiteralPath (
        Join-Path $processorRoot 'host.json'
    ) -Raw | ConvertFrom-Json
    Assert-True (
        $hostConfiguration.logging.applicationInsights.samplingSettings.excludedTypes -match '(^|;)Trace($|;)'
    ) 'Checkpoint AppTraces must not be sampled.'

    Write-Host 'Validated Function package contracts and allocation settings.'
}

function Test-CiWorkflowContracts {
    $workflowPath = Join-Path $repositoryRoot '.github\workflows\ci.yml'
    Assert-True (
        Test-Path -LiteralPath $workflowPath -PathType Leaf
    ) 'The CI workflow is missing.'

    $workflow = Get-Content -LiteralPath $workflowPath -Raw
    Assert-True (
        $workflow -notmatch '(?m)^\s*pull_request_target\s*:'
    ) 'The CI workflow must not use pull_request_target.'
    Assert-True (
        $workflow -match '(?m)^permissions:\r?\n\s+contents:\s+read\s*$'
    ) 'The CI workflow must grant only read access to repository contents.'
    Assert-True (
        $workflow.Contains('persist-credentials: false')
    ) 'The CI checkout must not persist the GitHub token.'
    Assert-True (
        $workflow -notmatch 'azure/login|AZURE_CREDENTIALS|id-token:\s+write'
    ) 'The build-only CI workflow must not configure Azure credentials.'
    Assert-True (
        $workflow.Contains('python-version: "3.12"')
    ) 'The CI workflow must run Python 3.12.'
    Assert-True (
        $workflow.Contains('node-version: "24"')
    ) 'The CI workflow must run Node.js 24.'
    Assert-True (
        $workflow.Contains('https://packagefeedproxy.microsoft.io/pypi/simple')
    ) 'The CI workflow must use the Microsoft Python package proxy.'
    Assert-True (
        $workflow.Contains('https://packagefeedproxy.microsoft.io/npm/')
    ) 'The CI workflow must use the Microsoft npm package proxy.'
    Assert-True (
        $workflow.Contains('.\scripts\test-token-cost-attribution.ps1')
    ) 'The CI workflow does not run the release acceptance script.'
    Assert-True (
        $workflow.Contains('npm.cmd audit --audit-level=high --prefix .\src\web')
    ) 'The CI workflow must fail on high or critical npm audit findings.'
    Assert-True (
        -not $workflow.Contains('postdeploy:auth-acceptance')
    ) 'The offline CI workflow must not run the postdeployment authentication harness.'

    $actionReferences = @(
        [regex]::Matches($workflow, '(?m)^\s*uses:\s+[^@\s]+@([^\s#]+)') |
            ForEach-Object { $_.Groups[1].Value }
    )
    Assert-True ($actionReferences.Count -gt 0) 'The CI workflow uses no actions.'
    foreach ($reference in $actionReferences) {
        Assert-True (
            $reference -match '^[0-9a-f]{40}$'
        ) "The CI workflow action reference '$reference' is not a full commit SHA."
    }

    Write-Host 'Validated the least-privilege CI workflow and pinned actions.'
}

Push-Location $repositoryRoot
try {
    & (Join-Path $PSScriptRoot 'verify-finops-release.ps1')
    & (Join-Path $PSScriptRoot 'test-apim-usage-policies.ps1')
    Invoke-CheckedNative `
        -Command 'pwsh' `
        -Arguments @(
            '-NoProfile'
            '-File'
            (Join-Path $PSScriptRoot 'test-lifecycle-hooks.ps1')
        ) `
        -Description 'lifecycle hook contract tests'
    Invoke-CheckedNative `
        -Command 'pwsh' `
        -Arguments @(
            '-NoProfile'
            '-File'
            (Join-Path $PSScriptRoot 'test-hmac-bootstrap.ps1')
        ) `
        -Description 'HMAC and lifecycle Bicep tests'
    Test-DashboardContracts
    Test-WorkbookContracts
    Test-TeardownContracts
    Test-BicepBuild
    Test-FunctionPackageContracts
    Test-CiWorkflowContracts
    Invoke-CheckedNative `
        -Command 'python' `
        -Arguments @('-m', 'unittest', 'discover', '-s', '.\src\usage-processor\tests') `
        -Description 'Python usage processor tests'
    Invoke-CheckedNative `
        -Command 'npm.cmd' `
        -Arguments @('run', 'build', '--prefix', '.\src\web') `
        -Description 'Node web build'
    foreach ($test in @(
        'test:auth-logging'
        'test:auth-validation'
        'test:easyauth-harness-guards'
        'test:dependency-security'
        'test:usage'
        'test:weather'
    )) {
        Invoke-CheckedNative `
            -Command 'npm.cmd' `
            -Arguments @('run', $test, '--prefix', '.\src\web') `
            -Description "Node $test tests"
    }
}
finally {
    Pop-Location
}

Write-Host 'All deterministic token cost attribution checks passed.' -ForegroundColor Green
