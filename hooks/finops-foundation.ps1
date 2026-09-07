function Get-FinOpsDataFactoryPrincipalId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][guid] $SubscriptionId,
        [Parameter(Mandatory = $true)][string] $ResourceGroupName,
        [Parameter(Mandatory = $true)][string] $HubName
    )

    $groupId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
    $hubId = "$groupId/providers/Microsoft.Cloud/hubs/$HubName"
    $encodedGroup = [Uri]::EscapeDataString($ResourceGroupName)
    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$encodedGroup/providers/Microsoft.DataFactory/factories?api-version=2018-06-01"
    $output = & az rest --method GET --uri $uri --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read the existing FinOps foundation: $($output -join "`n")"
    }
    $result = $output -join "`n" | ConvertFrom-Json -AsHashtable
    if ($result -isnot [System.Collections.IDictionary] -or $result['value'] -isnot [array] -or $result['nextLink']) {
        throw 'The FinOps Data Factory listing is malformed or incomplete.'
    }
    $factories = @($result['value'] | Where-Object {
        $null -ne $_['tags'] -and $_['tags']['cm-resource-parent'] -ieq $hubId
    })
    if ($factories.Count -eq 0) {
        return $null
    }
    if ($factories.Count -ne 1) {
        throw 'Expected one Data Factory owned by this FinOps hub.'
    }
    $factory = $factories[0]
    if ($factory['id'] -ine "$groupId/providers/Microsoft.DataFactory/factories/$($factory['name'])") {
        throw 'The existing FinOps Data Factory resolved outside the expected resource group.'
    }
    $principalId = [guid]::Empty
    if ($null -eq $factory['identity'] -or
        -not [guid]::TryParse($factory['identity']['principalId'], [ref]$principalId) -or
        $principalId -eq [guid]::Empty) {
        throw 'The existing FinOps Data Factory has no valid managed identity.'
    }
    Write-Host 'Reusing the existing FinOps Data Factory identity; the managed-export pass will update the complete hub.'
    return $principalId.ToString()
}

function Invoke-FinOpsExportConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][guid] $SubscriptionId,
        [Parameter(Mandatory = $true)][string] $ResourceGroupName,
        [Parameter(Mandatory = $true)][string] $DataFactoryName,
        [ValidateRange(1, 180)][int] $MaxPollAttempts = 90,
        [ValidateRange(0, 60)][int] $PollIntervalSeconds = 10
    )

    $group = [Uri]::EscapeDataString($ResourceGroupName)
    $factory = [Uri]::EscapeDataString($DataFactoryName)
    $baseUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$group/providers/Microsoft.DataFactory/factories/$factory"
    $output = & az rest --method POST `
        --uri "$baseUri/pipelines/config_ConfigureExports/createRun?api-version=2018-06-01" `
        --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not start FinOps export configuration: $($output -join "`n")"
    }
    $response = $output -join "`n" | ConvertFrom-Json -AsHashtable
    $runId = [guid]::Empty
    if (-not [guid]::TryParse($response['runId'], [ref]$runId) -or $runId -eq [guid]::Empty) {
        throw 'FinOps export configuration returned no valid pipeline run ID.'
    }
    Write-Host "Running Microsoft config_ConfigureExports to initialize the scoped FOCUS exports. Run: $runId"
    for ($attempt = 1; $attempt -le $MaxPollAttempts; $attempt++) {
        $output = & az rest --method GET `
            --uri "$baseUri/pipelineruns/${runId}?api-version=2018-06-01" `
            --only-show-errors --output json 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Could not read FinOps configuration run ${runId}: $($output -join "`n")"
        }
        $run = $output -join "`n" | ConvertFrom-Json -AsHashtable
        if ($run['status'] -eq 'Succeeded') {
            Write-Host 'Microsoft FinOps export configuration completed.'
            return $runId.ToString()
        }
        if ($run['status'] -notin @('Queued', 'InProgress', 'Canceling')) {
            throw "FinOps configuration run $runId ended with status '$($run['status'])': $($run['message'])"
        }
        if ($attempt -lt $MaxPollAttempts) {
            Start-Sleep -Seconds $PollIntervalSeconds
        }
    }
    throw "FinOps configuration run $runId did not complete within the polling limit. Inspect this run before retrying."
}
