<#
.SYNOPSIS
  Run staggered parallel traffic lanes for models and the weather agent.

.DESCRIPTION
  Starts four direct-model lanes, one lower-frequency agent lane, and one
  low-frequency guardrail lane. Each lane uses scripts/traffic-simulator.ps1
  and writes its own activity log and summary. The parent waits for all lanes
  and writes an aggregate summary.

.EXAMPLE
  pwsh ./scripts/run-parallel-traffic-simulation.ps1 `
    -DurationMinutes 120 `
    -OutputDirectory "$env:TEMP\ai-observability-parallel-traffic" `
    -RequireCleanWorktree
#>
[CmdletBinding()]
param(
  [ValidateRange(1, 1440)]
  [int]$DurationMinutes = 120,

  [ValidateRange(1, 10000)]
  [int]$MaxRequestsPerModelLane = 1000,

  [ValidateRange(1, 2000)]
  [int]$MaxAgentRequests = 250,

  [ValidateRange(1, 1000)]
  [int]$MaxGuardrailRequests = 100,

  [ValidateRange(0, 100)]
  [int]$CacheTrafficPercent = 40,

  [ValidateRange(0, 3600)]
  [int]$MinimumModelDelaySeconds = 15,

  [ValidateRange(0, 3600)]
  [int]$MaximumModelDelaySeconds = 35,

  [ValidateRange(0, 3600)]
  [int]$MinimumAgentDelaySeconds = 90,

  [ValidateRange(0, 3600)]
  [int]$MaximumAgentDelaySeconds = 150,

  [ValidateRange(0, 3600)]
  [int]$MinimumGuardrailDelaySeconds = 180,

  [ValidateRange(0, 3600)]
  [int]$MaximumGuardrailDelaySeconds = 300,

  [string]$OutputDirectory = (Join-Path $env:TEMP 'ai-observability-parallel-traffic'),

  [switch]$RequireCleanWorktree,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$simulatorPath = Join-Path $PSScriptRoot 'traffic-simulator.ps1'

if (-not (Test-Path -LiteralPath $simulatorPath)) {
  throw "Traffic simulator not found: $simulatorPath"
}
if ($MinimumModelDelaySeconds -gt $MaximumModelDelaySeconds) {
  throw 'MinimumModelDelaySeconds cannot be greater than MaximumModelDelaySeconds.'
}
if ($MinimumAgentDelaySeconds -gt $MaximumAgentDelaySeconds) {
  throw 'MinimumAgentDelaySeconds cannot be greater than MaximumAgentDelaySeconds.'
}
if ($MinimumGuardrailDelaySeconds -gt $MaximumGuardrailDelaySeconds) {
  throw 'MinimumGuardrailDelaySeconds cannot be greater than MaximumGuardrailDelaySeconds.'
}
if ($RequireCleanWorktree -and @(git -C $repoRoot status --porcelain).Count -gt 0) {
  throw 'The worktree contains uncommitted changes. Commit before starting the simulation.'
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$sourceCommit = ([string](git -C $repoRoot rev-parse HEAD)).Trim()
$startedUtc = [DateTime]::UtcNow

$laneDefinitions = @(
  [pscustomobject]@{
    Name = 'research-openai'
    Parameters = @{
      DurationMinutes = $DurationMinutes
      MaxRequests = $MaxRequestsPerModelLane
      Team = 'Research'
      Model = 'OpenAI'
      CacheTrafficPercent = $CacheTrafficPercent
      MinimumDelaySeconds = $MinimumModelDelaySeconds
      MaximumDelaySeconds = $MaximumModelDelaySeconds
      InitialDelaySeconds = 0
      RandomSeed = 202608261
    }
  },
  [pscustomobject]@{
    Name = 'research-claude'
    Parameters = @{
      DurationMinutes = $DurationMinutes
      MaxRequests = $MaxRequestsPerModelLane
      Team = 'Research'
      Model = 'Claude'
      CacheTrafficPercent = $CacheTrafficPercent
      MinimumDelaySeconds = $MinimumModelDelaySeconds
      MaximumDelaySeconds = $MaximumModelDelaySeconds
      InitialDelaySeconds = 5
      RandomSeed = 202608262
    }
  },
  [pscustomobject]@{
    Name = 'engineering-openai'
    Parameters = @{
      DurationMinutes = $DurationMinutes
      MaxRequests = $MaxRequestsPerModelLane
      Team = 'Engineering'
      Model = 'OpenAI'
      CacheTrafficPercent = $CacheTrafficPercent
      MinimumDelaySeconds = $MinimumModelDelaySeconds
      MaximumDelaySeconds = $MaximumModelDelaySeconds
      InitialDelaySeconds = 10
      RandomSeed = 202608263
    }
  },
  [pscustomobject]@{
    Name = 'engineering-claude'
    Parameters = @{
      DurationMinutes = $DurationMinutes
      MaxRequests = $MaxRequestsPerModelLane
      Team = 'Engineering'
      Model = 'Claude'
      CacheTrafficPercent = $CacheTrafficPercent
      MinimumDelaySeconds = $MinimumModelDelaySeconds
      MaximumDelaySeconds = $MaximumModelDelaySeconds
      InitialDelaySeconds = 15
      RandomSeed = 202608264
    }
  },
  [pscustomobject]@{
    Name = 'weather-agent'
    Parameters = @{
      DurationMinutes = $DurationMinutes
      MaxRequests = $MaxAgentRequests
      AgentOnly = $true
      CacheTrafficPercent = 0
      MinimumDelaySeconds = $MinimumAgentDelaySeconds
      MaximumDelaySeconds = $MaximumAgentDelaySeconds
      InitialDelaySeconds = 30
      RandomSeed = 202608265
    }
  },
  [pscustomobject]@{
    Name = 'guardrails'
    Parameters = @{
      DurationMinutes = $DurationMinutes
      MaxRequests = $MaxGuardrailRequests
      GuardrailOnly = $true
      Team = 'Research'
      Model = 'OpenAI'
      CacheTrafficPercent = 0
      MinimumDelaySeconds = $MinimumGuardrailDelaySeconds
      MaximumDelaySeconds = $MaximumGuardrailDelaySeconds
      InitialDelaySeconds = 45
      RandomSeed = 202608266
    }
  }
)

$jobs = foreach ($lane in $laneDefinitions) {
  $lane.Parameters.LogPath = Join-Path $OutputDirectory "$($lane.Name).log"
  $lane.Parameters.SummaryPath = Join-Path $OutputDirectory "$($lane.Name)-summary.json"
  $lane.Parameters.RequireCleanWorktree = [bool]$RequireCleanWorktree
  $lane.Parameters.DryRun = [bool]$DryRun
  Write-Host "Starting lane $($lane.Name) with offset $($lane.Parameters.InitialDelaySeconds)s."
  Start-ThreadJob `
    -Name $lane.Name `
    -ThrottleLimit $laneDefinitions.Count `
    -ScriptBlock {
      param($Path, $Parameters)
      & $Path @Parameters
    } `
    -ArgumentList $simulatorPath, $lane.Parameters
}

$jobs | Wait-Job | Out-Null
$failedJobs = @($jobs | Where-Object State -ne 'Completed')
foreach ($job in $jobs) {
  Receive-Job -Job $job | Out-Null
  Remove-Job -Job $job -Force
}

$laneSummaries = @(
  foreach ($lane in $laneDefinitions) {
    $summaryPath = Join-Path $OutputDirectory "$($lane.Name)-summary.json"
    if (Test-Path -LiteralPath $summaryPath) {
      Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    }
  }
)

$aggregate = [ordered]@{
  sourceCommit = $sourceCommit
  startUtc = $startedUtc.ToString('o')
  finishUtc = [DateTime]::UtcNow.ToString('o')
  durationMinutes = $DurationMinutes
  laneCount = $laneDefinitions.Count
  completedLanes = $laneSummaries.Count
  failedLanes = $failedJobs.Count
  sent = [int](($laneSummaries | Measure-Object sent -Sum).Sum)
  succeeded = [int](($laneSummaries | Measure-Object succeeded -Sum).Sum)
  failed = [int](($laneSummaries | Measure-Object failed -Sum).Sum)
  quotaLimited = [int](($laneSummaries | Measure-Object quotaLimited -Sum).Sum)
  lanes = @($laneDefinitions.Name)
}

$aggregatePath = Join-Path $OutputDirectory 'parallel-summary.json'
$aggregate | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $aggregatePath -Encoding utf8
Write-Host ($aggregate | ConvertTo-Json -Depth 6)
Write-Host "Aggregate summary written to $aggregatePath"

if ($failedJobs.Count -gt 0) {
  throw "$($failedJobs.Count) traffic lane(s) failed."
}
