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

function Resolve-BicepExecutable {
    $candidates = [System.Collections.Generic.List[string]]::new()

    if ($env:BICEP_CLI_PATH) {
        $candidates.Add($env:BICEP_CLI_PATH)
    }

    $candidates.Add((Join-Path $HOME '.azure\bin\bicep.exe'))

    $pathCommand = Get-Command bicep -CommandType Application -ErrorAction SilentlyContinue
    if ($null -ne $pathCommand -and $pathCommand.Source) {
        $candidates.Add($pathCommand.Source)
    }

    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            continue
        }

        $resolvedCandidate = (Resolve-Path -LiteralPath $candidate).Path
        $fileName = [System.IO.Path]::GetFileName($resolvedCandidate)
        if ($fileName -in @('bicep', 'bicep.exe')) {
            return $resolvedCandidate
        }
    }

    throw 'The direct Bicep CLI executable is not available. Set BICEP_CLI_PATH, install bicep on PATH, or install it at $HOME\.azure\bin\bicep.exe.'
}
function Test-BicepBuilds {
    param(
        [Parameter(Mandatory = $true)][string[]] $RelativePaths
    )

    $bicep = Resolve-BicepExecutable
    Assert-True (
        [System.IO.Path]::GetFileName($bicep) -in @('bicep', 'bicep.exe')
    ) 'The lifecycle tests must call the direct Bicep executable, not az bicep.'
    $temporaryFiles = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($relativePath in $RelativePaths) {
            $sourcePath = Join-Path $repositoryRoot $relativePath
            $temporaryFile = Join-Path $PSScriptRoot ('.' + [System.IO.Path]::GetFileNameWithoutExtension($relativePath) + "-$PID.json")
            $temporaryFiles.Add($temporaryFile)
            $output = @(& $bicep build $sourcePath --outfile $temporaryFile 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "Bicep build failed for ${relativePath}: $($output -join "`n")"
            }
            Assert-True (Test-Path -LiteralPath $temporaryFile -PathType Leaf) "The Bicep build did not create output for $relativePath."
        }
    }
    finally {
        foreach ($temporaryFile in $temporaryFiles) {
            Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-HmacBootstrapContracts {
    $identityVault = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra\modules\identity-vault.bicep') -Raw

    Assert-True (
        $identityVault.Contains("--write-out '%{http_code}'")
    ) 'The HMAC bootstrap no longer records the Key Vault secret GET status code.'
    Assert-True (
        $identityVault.Contains('case "$secret_status" in')
    ) 'The HMAC bootstrap must branch on the Key Vault secret GET status.'
    Assert-True (
        $identityVault.Contains('create_secret() {')
    ) 'The HMAC bootstrap must keep the secret-creation helper.'
    Assert-True (
        $identityVault.Contains('if ! secret_status="$(curl --silent --show-error \')
    ) 'The HMAC bootstrap must retry transport failures without creating a secret.'
    Assert-True (
        $identityVault.Contains('if [ -z "$token" ] || [ "$token" = ''null'' ]; then')
    ) 'The HMAC bootstrap must reject missing managed-identity access tokens.'

    $createSecretStart = $identityVault.IndexOf('create_secret() {')
    $createSecretEnd = $identityVault.IndexOf('for attempt in $(seq 1 60); do', $createSecretStart)
    $existingStart = $identityVault.IndexOf('200)')
    $missingStart = $identityVault.IndexOf('404)')
    $fallbackStart = $identityVault.IndexOf('*)')
    $esacIndex = $identityVault.IndexOf('esac', $fallbackStart)

    Assert-True ($createSecretStart -ge 0 -and $createSecretEnd -gt $createSecretStart) 'The secret-creation helper block is missing.'
    Assert-True ($existingStart -ge 0 -and $missingStart -gt $existingStart) 'The existing-secret branch is missing from the HMAC bootstrap.'
    Assert-True ($fallbackStart -gt $missingStart -and $esacIndex -gt $fallbackStart) 'The transient-failure branch is missing from the HMAC bootstrap.'

    $createSecretBlock = $identityVault.Substring($createSecretStart, $createSecretEnd - $createSecretStart)
    $existingBranch = $identityVault.Substring($existingStart, $missingStart - $existingStart)
    $missingBranch = $identityVault.Substring($missingStart, $fallbackStart - $missingStart)
    $fallbackBranch = $identityVault.Substring($fallbackStart, $esacIndex - $fallbackStart)

    Assert-True (
        $createSecretBlock.Contains('-X PUT')
    ) 'The HMAC bootstrap must keep the secret creation PUT operation.'
    Assert-True (
        -not $existingBranch.Contains('create_secret') -and -not $existingBranch.Contains('-X PUT')
    ) 'The HMAC bootstrap must not rotate an existing secret.'
    Assert-True (
        $missingBranch.Contains('create_secret')
    ) 'The HMAC bootstrap must create the secret after a confirmed 404 response.'
    Assert-True (
        -not $fallbackBranch.Contains('create_secret') -and -not $fallbackBranch.Contains('-X PUT')
    ) 'The HMAC bootstrap must not create or rotate the secret after a transient or authorization failure.'

    Write-Host 'Validated HMAC bootstrap existing, missing, and transient-failure contracts.'
}

function Test-AllocationObservabilityContracts {
    $observabilityModule = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra\modules\usage-observability.bicep') -Raw
    $allocationColumns = [System.Text.RegularExpressions.Regex]::Match(
        $observabilityModule,
        'var allocationColumns = \[(?<body>.*?)\r?\n\]',
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    ).Groups['body'].Value

    Assert-True ([bool]$allocationColumns) 'The allocation column contract is missing.'
    foreach ($column in @(
        "{ name: 'RecordId', type: 'string' }"
        "{ name: 'RecordType', type: 'string' }"
        "{ name: 'ExpectedRecordCount', type: 'long' }"
    )) {
        Assert-True (
            $allocationColumns.Contains($column)
        ) "The allocation column contract is missing $column."
    }

    $allocationColumnUses = @(
        [System.Text.RegularExpressions.Regex]::Matches(
            $observabilityModule,
            '(?m)^\s+columns: allocationColumns\s*$'
        )
    )
    Assert-True (
        $allocationColumnUses.Count -eq 2
    ) 'The allocation custom table and DCR stream must both use allocationColumns.'

    Write-Host 'Validated allocation completion columns and shared table/stream schema.'
}
function Test-FlexConsumptionRuntimeContracts {
    $processorModule = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra\modules\usage-processor.bicep') -Raw

    Assert-True (
        $processorModule.Contains('functionAppConfig: {')
    ) 'The usage processor must configure the Flex Consumption runtime with functionAppConfig.'
    Assert-True (
        $processorModule.Contains("name: 'python'")
    ) 'The usage processor must declare the Python runtime name in functionAppConfig.'
    Assert-True (
        $processorModule.Contains("version: '3.12'")
    ) 'The usage processor must declare the Python runtime version in functionAppConfig.'
    Assert-True (
        -not $processorModule.Contains('FUNCTIONS_WORKER_RUNTIME')
    ) 'The usage processor must not set FUNCTIONS_WORKER_RUNTIME on Flex Consumption.'
    Assert-True (
        -not $processorModule.Contains('FUNCTIONS_EXTENSION_VERSION')
    ) 'The usage processor must not set FUNCTIONS_EXTENSION_VERSION on Flex Consumption.'
    Assert-True (
        $processorModule.Contains("CHECKPOINT_STALE_SECONDS: '900'")
    ) 'The usage processor must set CHECKPOINT_STALE_SECONDS explicitly.'
    Assert-True (
        $processorModule.Contains("CHECKPOINT_IDLE_SECONDS: '900'")
    ) 'The usage processor must set CHECKPOINT_IDLE_SECONDS explicitly.'

    Write-Host 'Validated Flex Consumption runtime and checkpoint threshold settings.'
}

function Test-RemoteBuildFeedContracts {
    $processorModule = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra\modules\usage-processor.bicep') -Raw
    $appServiceModule = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra\modules\app-service.bicep') -Raw

    Assert-True (
        $processorModule.Contains("PIP_INDEX_URL: 'https://packagefeedproxy.microsoft.io/pypi/simple'")
    ) 'The Flex Consumption Function App must set PIP_INDEX_URL for remote Python builds.'
    Assert-True (
        $appServiceModule -match "(?s)name: 'SCM_DO_BUILD_DURING_DEPLOYMENT'\s+value: 'true'"
    ) 'The web app must keep SCM_DO_BUILD_DURING_DEPLOYMENT enabled for remote builds.'
    Assert-True (
        $appServiceModule -match "(?s)name: 'NPM_CONFIG_REGISTRY'\s+value: 'https://packagefeedproxy.microsoft.io/npm/'"
    ) 'The web app must set NPM_CONFIG_REGISTRY for remote npm builds.'
    Assert-True (
        -not $appServiceModule.Contains('NPM_CONFIG_REPLACE_REGISTRY_HOST')
    ) 'The web app must not set NPM_CONFIG_REPLACE_REGISTRY_HOST.'

    Write-Host 'Validated remote build package feed contracts.'
}

function Test-BlobDiagnosticsContracts {
    $storageModule = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra\modules\usage-storage.bicep') -Raw
    $alertsModule = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra\modules\usage-alerts.bicep') -Raw
    $blobBlock = [System.Text.RegularExpressions.Regex]::Match(
        $storageModule,
        "resource blobDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = \{(?<body>.*?)\n\}",
        [System.Text.RegularExpressions.RegexOptions]::Singleline
    ).Groups['body'].Value

    Assert-True ([bool]$blobBlock) 'The blob diagnostics resource is missing.'
    Assert-True (
        $blobBlock.Contains("logAnalyticsDestinationType: 'Dedicated'")
    ) 'The blob diagnostics must export to Dedicated Log Analytics tables.'
    Assert-True (
        $alertsModule.Contains('StorageBlobLogs | where')
    ) 'The quarantine alert must continue to query StorageBlobLogs.'

    Write-Host 'Validated blob diagnostics and quarantine alert table alignment.'
}

function Test-CheckpointAlertContracts {
    $alertsModule = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra\modules\usage-alerts.bicep') -Raw
    $checkpointStart = $alertsModule.IndexOf("resource checkpointHealthAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {")
    $nextResourceStart = $alertsModule.IndexOf('resource staleUsageAlert ', $checkpointStart)

    Assert-True (
        $checkpointStart -ge 0 -and $nextResourceStart -gt $checkpointStart
    ) 'The checkpoint health alert resource is missing.'
    $checkpointBlock = $alertsModule.Substring($checkpointStart, $nextResourceStart - $checkpointStart)

    Assert-True (
        $checkpointBlock.Contains('AppTraces |')
    ) 'The checkpoint health alert must query AppTraces.'
    Assert-True (
        $checkpointBlock.Contains('let CheckpointPrefix = "UsageProcessorCheckpointStatus "') -and
        $checkpointBlock.Contains('Message startswith CheckpointPrefix')
    ) 'The checkpoint health alert must filter on the UsageProcessorCheckpointStatus message prefix.'
    Assert-True (
        $checkpointBlock.Contains('parse_json(substring(Message, strlen(CheckpointPrefix)))')
    ) 'The checkpoint health alert must parse the compact JSON payload from Message.'
    Assert-True (
        -not $checkpointBlock.Contains('Properties["eventHubName"]') -and
        -not $checkpointBlock.Contains('customDimensions')
    ) 'The checkpoint health alert must not rely on AppTraces Properties or customDimensions for checkpoint telemetry.'
    Assert-True (
        -not $checkpointBlock.Contains('Message == "UsageProcessorCheckpointStatus"')
    ) 'The checkpoint health alert must not use exact Message equality for checkpoint telemetry.'
    foreach ($field in @(
        'Checkpoint.eventHubName'
        'Checkpoint.consumerGroup'
        'Checkpoint.partitionId'
        'Checkpoint.status'
        'Checkpoint.checkpointAgeSeconds'
        'Checkpoint.eventAgeSeconds'
        'Checkpoint.checkpointSequenceNumber'
        'Checkpoint.lastEnqueuedSequenceNumber'
        'Checkpoint.sequenceLag'
        'Checkpoint.checkpointLastModifiedUtc'
        'Checkpoint.lastEnqueuedTimeUtc'
        'Checkpoint.staleThresholdSeconds'
        'Checkpoint.idleThresholdSeconds'
    )) {
        Assert-True (
            $checkpointBlock.Contains($field)
        ) "The checkpoint health alert is missing the required telemetry field $field."
    }
    Assert-True (
        $checkpointBlock.Contains('EventHubName =~ "${usageEventHubName}" and ConsumerGroup =~ "${usageEventHubConsumerGroupName}"')
    ) 'The checkpoint health alert must filter to the official usage event hub and consumer group.'
    Assert-True (
        $checkpointBlock.Contains('summarize arg_max(TimeGenerated, EventHubName, ConsumerGroup, Status, CheckpointAgeSeconds, EventAgeSeconds, CheckpointSequenceNumber, LastEnqueuedSequenceNumber, SequenceLag, CheckpointLastModifiedUtc, LastEnqueuedTimeUtc, StaleThresholdSeconds, IdleThresholdSeconds) by PartitionId')
    ) 'The checkpoint health alert must evaluate the latest trace for each partition.'
    Assert-True (
        $checkpointBlock.Contains('RecentCheckpointStatus | where Status in ("stale", "missing", "invalid")')
    ) 'The checkpoint health alert must alert only on stale, missing, or invalid partitions.'
    Assert-True (
        -not $checkpointBlock.Contains('initializing')
    ) 'The checkpoint health alert must not reference the removed initializing status.'
    Assert-True (
        $checkpointBlock.Contains("description: 'Detects partitions whose latest checkpoint status is stale, missing, or invalid while ignoring healthy, lagging, and idle partitions.'")
    ) 'The checkpoint health alert description must match the final status contract.'
    Assert-True (
        $checkpointBlock.Contains('numberOfEvaluationPeriods: 3') -and
        $checkpointBlock.Contains('minFailingPeriodsToAlert: 3')
    ) 'The checkpoint health alert must require three of three failing evaluation periods.'

    Write-Host 'Validated checkpoint health alert JSON telemetry and outage filters.'
}
function Test-AllocationFreshnessAlertContracts {
    $alertsModule = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra\modules\usage-alerts.bicep') -Raw
    $freshnessStart = $alertsModule.IndexOf("resource allocationStaleAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {")
    $nextResourceStart = $alertsModule.IndexOf("resource reconciliationDriftAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {", $freshnessStart)

    Assert-True (
        $freshnessStart -ge 0 -and $nextResourceStart -gt $freshnessStart
    ) 'The allocation freshness alert resource is missing.'
    $freshnessBlock = $alertsModule.Substring($freshnessStart, $nextResourceStart - $freshnessStart)

    Assert-True (
        $freshnessBlock.Contains('RecordType == "allocation"')
    ) 'The allocation freshness alert must read allocation records only from allocation rows.'
    Assert-True (
        $freshnessBlock.Contains('summarize arg_max(TimeGenerated, *) by RunId, RecordId')
    ) 'The allocation freshness alert must deduplicate allocation rows by RunId and RecordId.'
    Assert-True (
        $freshnessBlock.Contains('RecordType == "run-complete"')
    ) 'The allocation freshness alert must read completion records from run-complete rows.'
    Assert-True (
        $freshnessBlock.Contains('ActualRecordCount = count() by RunId')
    ) 'The allocation freshness alert must calculate the actual allocation row count for each run.'
    Assert-True (
        $freshnessBlock.Contains('ActualRecordCount == ExpectedRecordCount')
    ) 'The allocation freshness alert must require a verified complete run before freshness evaluation.'
    Assert-True (
        $freshnessBlock.Contains('let ScopedCompleteRuns = CompleteRuns | where SourceType == "${finopsHubFocusSourceType}" and SourceScope =~ "${workloadResourceGroupId}" | summarize arg_max(TimeGenerated, *) by SourceType, SourceScope, SourcePath')
    ) 'The allocation freshness alert must compute freshness from scope-filtered FOCUS completed runs.'
    Assert-True (
        $freshnessBlock.Contains('union (ScopedCompleteRuns | summarize LastSeen=max(TimeGenerated)), (print LastSeen=datetime(1970-01-01))')
    ) 'The allocation freshness alert must fall back to an empty baseline only after scope-filtered completion lookup.'
    Assert-True (
        -not $freshnessBlock.Contains('IncludedInWorkloadTotal == true | summarize LastSeen=max(TimeGenerated)') -and
        -not $freshnessBlock.Contains('dcount(RecordId)')
    ) 'The allocation freshness alert must not use raw workload rows or approximate counts to determine freshness.'

    Write-Host 'Validated allocation freshness alert latest-complete-run contract.'
}

function Test-ReconciliationAlertContracts {
    $alertsModule = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra\modules\usage-alerts.bicep') -Raw
    $reconciliationStart = $alertsModule.IndexOf("resource reconciliationDriftAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {")
    $nextResourceStart = $alertsModule.IndexOf('output actionGroupId string = actionGroup.id', $reconciliationStart)

    Assert-True (
        $reconciliationStart -ge 0 -and $nextResourceStart -gt $reconciliationStart
    ) 'The reconciliation drift alert resource is missing.'
    $reconciliationBlock = $alertsModule.Substring($reconciliationStart, $nextResourceStart - $reconciliationStart)

    Assert-True (
        $reconciliationBlock.Contains('RecordType == "allocation"')
    ) 'The reconciliation drift alert must read allocation records only from allocation rows.'
    Assert-True (
        $reconciliationBlock.Contains('summarize arg_max(TimeGenerated, *) by RunId, RecordId')
    ) 'The reconciliation drift alert must deduplicate allocation rows by RunId and RecordId.'
    Assert-True (
        $reconciliationBlock.Contains('RecordType == "run-complete"')
    ) 'The reconciliation drift alert must read completion records from run-complete rows.'
    Assert-True (
        $reconciliationBlock.Contains('ActualRecordCount = count() by RunId')
    ) 'The reconciliation drift alert must calculate the actual allocation row count for each run.'
    Assert-True (
        $reconciliationBlock.Contains('ActualRecordCount == ExpectedRecordCount')
    ) 'The reconciliation drift alert must require a verified complete run before reconciliation.'
    Assert-True (
        $reconciliationBlock.Contains('let LatestRuns = CompleteRuns | where SourceType == "${finopsHubFocusSourceType}" and SourceScope =~ "${workloadResourceGroupId}" | summarize arg_max(TimeGenerated, *) by SourceType, SourceScope, SourcePath')
    ) 'The reconciliation drift alert must select the latest verified FOCUS run for each source path.'
    Assert-True (
        $reconciliationBlock.Contains('project RunId, CompletionTime = TimeGenerated')
    ) 'The reconciliation drift alert must evaluate the completion time of the verified latest run.'
    Assert-True (
        $reconciliationBlock.Contains('where CompletionTime > ago(1h)')
    ) 'The reconciliation drift alert must scope drift detection to recent verified runs.'
    Assert-True (
        $reconciliationBlock.Contains('join kind=inner (AllocationRows | where IncludedInWorkloadTotal == true) on RunId')
    ) 'The reconciliation drift alert must reconcile only workload-total allocation rows from the verified latest run.'
    Assert-True (
        -not $reconciliationBlock.Contains('summarize arg_max(TimeGenerated, *) by RecordId') -and
        -not $reconciliationBlock.Contains('dcount(RecordId)')
    ) 'The reconciliation drift alert must not deduplicate allocation rows by RecordId alone or use approximate counts.'
    Assert-True (
        -not $reconciliationBlock.Contains('let ScopedRows = AICostAllocation_CL | where SourceScope =~ "${workloadResourceGroupId}" and IncludedInWorkloadTotal == true; let LatestRuns = ScopedRows | summarize arg_max(TimeGenerated, RunId) by SourcePath')
    ) 'The reconciliation drift alert must not use the older unverified latest-run contract.'

    Write-Host 'Validated reconciliation drift alert latest-run contract.'
}
function Test-MonitoringWorkbookContracts {
    $monitoringModule = Get-Content -LiteralPath (Join-Path $repositoryRoot 'infra\modules\monitoring.bicep') -Raw

    Assert-True (
        $monitoringModule.Contains('var functionAppName = take(''aiobs-usage-func-${cleanSuffix}'', 60)')
    ) 'The monitoring module must derive the usage processor function app name.'
    Assert-True (
        $monitoringModule.Contains("var eventHubConsumerGroupName = 'processor'")
    ) 'The monitoring module must derive the checkpoint consumer group name.'
    Assert-True (
        $monitoringModule.Contains("'__FUNCTION_APP_NAME__'") -and $monitoringModule.Contains('workbookWithFunctionApp')
    ) 'The monitoring module must replace the workbook function app placeholder.'
    Assert-True (
        $monitoringModule.Contains("'__EVENT_HUB_CONSUMER_GROUP__'") -and $monitoringModule.Contains('workbookWithConsumerGroup')
    ) 'The monitoring module must replace the workbook consumer-group placeholder.'

    Write-Host 'Validated monitoring workbook checkpoint placeholder replacements.'
}

Push-Location $repositoryRoot
try {
    Test-BicepBuilds @(
        'infra\modules\app-service.bicep'
        'infra\modules\cost-management.bicep'
        'infra\modules\identity-vault.bicep'
        'infra\modules\monitoring.bicep'
        'infra\modules\usage-observability.bicep'
        'infra\modules\usage-processor.bicep'
        'infra\modules\usage-storage.bicep'
        'infra\modules\usage-alerts.bicep'
    )
    Test-HmacBootstrapContracts
    Test-AllocationObservabilityContracts
    Test-FlexConsumptionRuntimeContracts
    Test-RemoteBuildFeedContracts
    Test-BlobDiagnosticsContracts
    Test-CheckpointAlertContracts
    Test-AllocationFreshnessAlertContracts
    Test-ReconciliationAlertContracts
    Test-MonitoringWorkbookContracts
}
finally {
    Pop-Location
}

Write-Host 'HMAC and lifecycle Bicep checks passed.' -ForegroundColor Green