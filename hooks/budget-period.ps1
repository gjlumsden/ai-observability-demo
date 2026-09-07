function ConvertTo-BudgetDate {
    param([Parameter(Mandatory = $true)][DateTimeOffset] $Value)

    return $Value.ToUniversalTime().ToString(
        'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function Get-AzureBudgetPeriod {
    param(
        [Parameter(Mandatory = $true)][guid] $SubscriptionId,
        [Parameter(Mandatory = $true)][string] $ResourceGroupName,
        [Parameter(Mandatory = $true)][string] $BudgetName,
        [DateTimeOffset] $Now = [DateTimeOffset]::UtcNow
    )

    $groupSegment = [Uri]::EscapeDataString($ResourceGroupName)
    $budgetSegment = [Uri]::EscapeDataString($BudgetName)
    $uri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$groupSegment/providers/Microsoft.Consumption/budgets/${budgetSegment}?api-version=2024-08-01"
    $output = & az rest --only-show-errors --method GET --uri $uri `
        --query properties.timePeriod --output json 2>&1
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
        if (-not $output) {
            throw "The budget lookup returned an empty response for $BudgetName."
        }
        $period = $output -join "`n" | ConvertFrom-Json -AsHashtable
        if (-not $period -or -not $period['startDate']) {
            throw "The existing budget $BudgetName has no valid start date."
        }
        return [pscustomobject]@{
            StartDate = ConvertTo-BudgetDate $period['startDate']
            EndDate = if ($period['endDate']) { ConvertTo-BudgetDate $period['endDate'] } else { '' }
            Exists = $true
        }
    }

    $errorText = $output -join "`n"
    $notFound = $errorText -match '^\s*ERROR:\s*\((ResourceNotFound|ResourceGroupNotFound|BudgetNotFound|NotFound|404)\)'
    if ($errorText -match '(?s)^\s*ERROR:\s*Not Found\((?<payload>\{.*\})\)\s*$') {
        $serviceError = $Matches['payload'] | ConvertFrom-Json -AsHashtable
        $notFound = [string]$serviceError['error']['code'] -ceq '404'
    }
    if ($notFound) {
        return [pscustomobject]@{
            StartDate = $Now.ToUniversalTime().ToString(
                'yyyy-MM-01', [System.Globalization.CultureInfo]::InvariantCulture
            )
            EndDate = ''
            Exists = $false
        }
    }

    throw "Could not read budget $BudgetName to preserve its period: $errorText"
}
