#requires -Version 7.2

function Get-FinOpsScheduleResource {
    param([System.Text.Json.Nodes.JsonNode] $Node)

    if ($Node -is [System.Text.Json.Nodes.JsonObject]) {
        if ($null -ne $Node['type'] -and
            $Node['type'].ToString() -eq 'Microsoft.DataFactory/factories/triggers' -and
            $Node['properties']['type'].ToString() -eq 'ScheduleTrigger') {
            Write-Output -NoEnumerate $Node
        }
        foreach ($entry in $Node) {
            Get-FinOpsScheduleResource $entry.Value
        }
    }
    elseif ($Node -is [System.Text.Json.Nodes.JsonArray]) {
        foreach ($item in $Node) {
            Get-FinOpsScheduleResource $item
        }
    }
}

function Get-FinOpsNamedActivity {
    param(
        [System.Text.Json.Nodes.JsonNode] $Node,
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Type
    )

    if ($Node -is [System.Text.Json.Nodes.JsonObject]) {
        if ($null -ne $Node['name'] -and $null -ne $Node['type'] -and
            $Node['name'].ToString() -ceq $Name -and $Node['type'].ToString() -ceq $Type) {
            Write-Output -NoEnumerate $Node
        }
        foreach ($entry in $Node) {
            Get-FinOpsNamedActivity -Node $entry.Value -Name $Name -Type $Type
        }
    }
    elseif ($Node -is [System.Text.Json.Nodes.JsonArray]) {
        foreach ($item in $Node) {
            Get-FinOpsNamedActivity -Node $item -Name $Name -Type $Type
        }
    }
}

function Update-FinOpsUtcSchedules {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $TemplateFile)

    $documentOptions = [System.Text.Json.JsonDocumentOptions]::new()
    $documentOptions.MaxDepth = 100
    $template = [System.Text.Json.Nodes.JsonNode]::Parse(
        (Get-Content -LiteralPath $TemplateFile -Raw), $null, $documentOptions
    )
    $schedules = @(Get-FinOpsScheduleResource $template)
    $expectedCounts = @{
        '2023-01-01T01:01:00' = 2
        '2023-01-05T01:11:00' = 1
    }
    if ($schedules.Count -ne 3) {
        throw 'Expected exactly three schedule definitions in the pinned FinOps v14 template.'
    }
    foreach ($schedule in $schedules) {
        $recurrence = $schedule['properties']['typeProperties']['recurrence']
        $start = $recurrence['startTime'].ToString()
        $zone = $recurrence['timeZone'].ToString()
        if (-not $expectedCounts.ContainsKey($start) -or
            $zone -cne "[reference('timeZones').outputs.Timezone.value]") {
            throw 'The FinOps v14 schedule definition changed. Review the UTC compatibility correction.'
        }
        $expectedCounts[$start]--
        # Mitigate microsoft/finops-toolkit#2157 without changing the pinned source or local-time schedules.
        $expression = "[if(equals(reference('timeZones').outputs.Timezone.value, 'UTC'), '${start}Z', '$start')]"
        $recurrence['startTime'] = [System.Text.Json.Nodes.JsonNode]::Parse(
            (ConvertTo-Json -InputObject $expression -Compress)
        )
    }
    if (@($expectedCounts.Values | Where-Object { $_ -ne 0 }).Count -ne 0) {
        throw 'The FinOps v14 schedule counts changed. The template was not written.'
    }
    $options = [System.Text.Json.JsonSerializerOptions]::new()
    $options.WriteIndented = $true
    $options.MaxDepth = 100
    [System.IO.File]::WriteAllText($TemplateFile, $template.ToJsonString($options), [System.Text.UTF8Encoding]::new($false))
    Write-Host 'Applied the conditional UTC start-time correction to three compiled FinOps schedule definitions.'
}

function Update-FinOpsExportRetries {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $TemplateFile)

    $documentOptions = [System.Text.Json.JsonDocumentOptions]::new()
    $documentOptions.MaxDepth = 100
    $template = [System.Text.Json.Nodes.JsonNode]::Parse(
        (Get-Content -LiteralPath $TemplateFile -Raw), $null, $documentOptions
    )
    $activities = @(
        Get-FinOpsNamedActivity -Node $template -Name 'Trigger export' -Type 'WebActivity'
    )
    if ($activities.Count -ne 1) {
        throw 'Expected exactly one Trigger export WebActivity in the pinned FinOps v14 template.'
    }

    $policy = $activities[0]['policy']
    if ($null -eq $policy -or
        $policy['timeout'].ToString() -cne '0.00:05:00' -or
        $policy['retry'].ToString() -cne '0' -or
        $policy['retryIntervalInSeconds'].ToString() -cne '30') {
        throw 'The FinOps v14 Trigger export retry policy changed. Review the 429 compatibility correction.'
    }

    $policy['retry'] = 3
    $policy['retryIntervalInSeconds'] = 60

    $options = [System.Text.Json.JsonSerializerOptions]::new()
    $options.WriteIndented = $true
    $options.MaxDepth = 100
    [System.IO.File]::WriteAllText(
        $TemplateFile,
        $template.ToJsonString($options),
        [System.Text.UTF8Encoding]::new($false)
    )
    Write-Host 'Applied bounded 60-second retries to the compiled FinOps export trigger.'
}
