# Dot-source this helper in hooks that need to verify Function App registrations.
# Usage:
#   . (Join-Path $PSScriptRoot 'function-readiness.ps1')
#   $names = Invoke-FunctionAppReadinessCheck -FunctionAppName ... -SubscriptionId ... `
#                -ResourceGroupName ... -ExpectedFunctions @('FuncA','FuncB')

function Invoke-FunctionAppReadinessCheck {
    <#
    .SYNOPSIS
        Polls az functionapp function list until all expected functions are registered
        or the attempt limit is reached, then throws if the registration set does not
        match expectations.
    .PARAMETER GetFunctionList
        Optional scriptblock injected for testing.  Receives ($FunctionAppName,
        $SubscriptionId, $ResourceGroupName) and must set $global:LASTEXITCODE.
        Defaults to the real az functionapp function list call.
    #>
    param(
        [Parameter(Mandatory = $true)][string]   $FunctionAppName,
        [Parameter(Mandatory = $true)][string]   $SubscriptionId,
        [Parameter(Mandatory = $true)][string]   $ResourceGroupName,
        [Parameter(Mandatory = $true)][string[]] $ExpectedFunctions,
        [int]         $MaxAttempts = 10,
        [int]         $DelaySeconds = 15,
        [scriptblock] $GetFunctionList = $null
    )

    if ($null -eq $GetFunctionList) {
        $GetFunctionList = {
            param($AppName, $SubId, $Rg)
            az functionapp function list `
                --subscription $SubId `
                --resource-group $Rg `
                --name $AppName `
                --query '[].name' `
                --output json `
                --only-show-errors
        }
    }

    $registeredFunctions = @()

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $listJson = & $GetFunctionList $FunctionAppName $SubscriptionId $ResourceGroupName
        if ($LASTEXITCODE -ne 0) {
            throw "Could not list functions for '$FunctionAppName' (attempt $attempt of $($MaxAttempts)). " +
                  "Check that the Function App exists and that the deployment principal has " +
                  "Microsoft.Web/sites/functions/read."
        }

        # az functionapp function list --query '[].name' returns '<appname>/<functionname>'.
        # Strip the '<appname>/' prefix to get the bare function name.
        $rawNames = @($listJson -join "`n" | ConvertFrom-Json)
        $registeredFunctions = @($rawNames | ForEach-Object {
            if ($_ -match '^[^/]+/(.+)$') { $Matches[1] } else { $_ }
        })

        $stillMissing = @($ExpectedFunctions | Where-Object { $registeredFunctions -notcontains $_ })
        if ($stillMissing.Count -eq 0) { break }

        if ($attempt -lt $MaxAttempts) {
            Write-Host ("  Attempt $attempt/$($MaxAttempts): {0}/{1} function(s) registered; " +
                        "waiting ${DelaySeconds}s for host sync." -f $registeredFunctions.Count, $ExpectedFunctions.Count)
            Start-Sleep -Seconds $DelaySeconds
        }
    }

    $missing    = @($ExpectedFunctions    | Where-Object { $registeredFunctions -notcontains $_ })
    $unexpected = @($registeredFunctions  | Where-Object { $ExpectedFunctions   -notcontains $_ })

    if ($missing.Count -gt 0 -or $unexpected.Count -gt 0) {
        $detail = [System.Collections.Generic.List[string]]::new()
        if ($missing.Count -gt 0) {
            $detail.Add("  Missing    : $($missing -join ', ')")
        }
        if ($unexpected.Count -gt 0) {
            $detail.Add("  Unexpected : $($unexpected -join ', ')")
        }
        $detail.Add("  Registered : $(if ($registeredFunctions.Count -gt 0) { $registeredFunctions -join ', ' } else { '(none)' })")
        throw ("Usage Function App '$FunctionAppName' has unexpected function registrations " +
               "after $MaxAttempts attempt(s).`n" +
               ($detail -join "`n") + "`n" +
               "Check App Insights for FunctionLoadError traces to identify the root cause.")
    }

    return $registeredFunctions
}