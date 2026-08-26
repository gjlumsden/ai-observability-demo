[CmdletBinding()]
param(
  [ValidateRange(1, 15)]
  [int]$Slide = 1,

  [ValidateSet('1h', '6h', '24h', '7d')]
  [string]$Range = '24h'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$presentationPath = Join-Path $PSScriptRoot 'presenter.html'

function Get-AzdEnvironmentValues {
  $values = @{}
  $output = azd env get-values --cwd $repoRoot 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw 'Could not read the active azd environment.'
  }

  foreach ($line in $output) {
    if ($line -match '^\s*([^=]+)=(.*)\s*$') {
      $values[$Matches[1].Trim()] = $Matches[2].Trim().Trim('"')
    }
  }
  return $values
}

function Get-RequiredValue {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Values,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($Values.ContainsKey($Name) -and $Values[$Name]) {
    return $Values[$Name]
  }
  throw "$Name is not configured in the active azd environment."
}

if (-not (Test-Path -LiteralPath $presentationPath)) {
  throw "Presentation not found: $presentationPath"
}

$requiredDiagramAssets = @(
  'ai-observability-architecture',
  'cost-governance-flow',
  'model-gateway-flow',
  'transaction-trace-flow',
  'weather-agent-attribution-flow'
) | ForEach-Object {
  @(
    (Join-Path $repoRoot "docs\diagrams\$_.png"),
    (Join-Path $repoRoot "docs\diagrams\$_.excalidraw")
  )
}
$missingDiagramAssets = @($requiredDiagramAssets | Where-Object {
  -not (Test-Path -LiteralPath $_)
})
if ($missingDiagramAssets.Count -gt 0) {
  throw "Presentation diagram asset not found: $($missingDiagramAssets[0])"
}

$values = Get-AzdEnvironmentValues
$tenantId = Get-RequiredValue $values 'AZURE_TENANT_ID'
$subscriptionId = Get-RequiredValue $values 'AZURE_SUBSCRIPTION_ID'
$resourceGroup = Get-RequiredValue $values 'AZURE_RESOURCE_GROUP'
$resourceSuffix = Get-RequiredValue $values 'AZURE_RESOURCE_SUFFIX'

$workbooksUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroup/providers/Microsoft.Insights/workbooks?api-version=2023-06-01"
$workbooksJson = az rest --only-show-errors --method get --uri $workbooksUri --output json
if ($LASTEXITCODE -ne 0) {
  throw 'Could not list the deployed workbooks.'
}
$workbooks = ($workbooksJson -join "`n" | ConvertFrom-Json).value
$workbook = $workbooks |
  Where-Object { $_.properties.displayName -eq 'AI Observability usage and cost governance' } |
  Select-Object -First 1
if (-not $workbook) {
  throw 'The AI Observability usage and cost governance workbook was not found.'
}

$edge = @(
  "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
  "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $edge) {
  throw 'Microsoft Edge was not found.'
}

$query = [ordered]@{
  slide = $Slide
  range = $Range
  tenantId = $tenantId
  subscriptionId = $subscriptionId
  resourceGroup = $resourceGroup
  suffix = $resourceSuffix
  workbookId = $workbook.name
  version = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}
$queryString = ($query.GetEnumerator() | ForEach-Object {
  '{0}={1}' -f [uri]::EscapeDataString([string]$_.Key), [uri]::EscapeDataString([string]$_.Value)
}) -join '&'

$fileUrl = ([uri]$presentationPath).AbsoluteUri
Start-Process -FilePath $edge -ArgumentList "$fileUrl`?$queryString"
Write-Host "Opened the demo guide at slide $Slide with the $Range monitoring range."
