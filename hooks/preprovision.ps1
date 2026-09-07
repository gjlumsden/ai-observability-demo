$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'budget-period.ps1')
foreach ($command in @('az', 'azd')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is required for the deployment lifecycle."
    }
}

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

function Test-ActionMatch {
  param(
      [Parameter(Mandatory = $true)][string] $Pattern,
      [Parameter(Mandatory = $true)][string] $Action
  )

  $expression = '^' + [Regex]::Escape($Pattern).Replace('\*', '.*') + '$'
  return $Action -match $expression
}

function Test-AzurePermission {
  param(
      [Parameter(Mandatory = $true)][object[]] $Permissions,
      [Parameter(Mandatory = $true)][string] $Action
  )

  foreach ($permission in $Permissions) {
      $allowed = @($permission.actions | Where-Object { Test-ActionMatch $_ $Action }).Count -gt 0
      $denied = @($permission.notActions | Where-Object { Test-ActionMatch $_ $Action }).Count -gt 0
      if ($allowed -and -not $denied) {
          return $true
      }
  }
  return $false
}

function Test-AzureResourceExists {
  param(
      [Parameter(Mandatory = $true)][string] $ResourceId,
      [Parameter(Mandatory = $true)][string] $ApiVersion
  )

  $output = & az rest `
      --only-show-errors `
      --method GET `
      --uri "https://management.azure.com${ResourceId}?api-version=${ApiVersion}" `
      --output none 2>&1
  if ($LASTEXITCODE -eq 0) {
      return $true
  }

  $message = $output -join "`n"
  if ($message -match 'NotFound|not found|could not be found|ResourceNotFound|does not exist') {
      return $false
  }

  throw "Could not inspect existing resource $ResourceId`: $message"
}

$values = Get-AzdEnvironmentValues
$subscriptionId = $values['AZURE_SUBSCRIPTION_ID']
if (-not $subscriptionId) {
  throw 'AZURE_SUBSCRIPTION_ID is not set in the azd environment.'
}

& az account set --subscription $subscriptionId --only-show-errors
if ($LASTEXITCODE -ne 0) {
  throw "Could not select Azure subscription $subscriptionId."
}

$subscriptionScope = "/subscriptions/$subscriptionId"
$resourceGroupName = if ($values['AZURE_RESOURCE_GROUP']) {
    $values['AZURE_RESOURCE_GROUP']
}
elseif ($values['AZURE_ENV_NAME']) {
    "rg-$($values['AZURE_ENV_NAME'])"
}
else {
    ''
}
$providerNamespaces = @(
    'Microsoft.CostManagement'
    'Microsoft.CostManagementExports'
    'Microsoft.DataFactory'
    'Microsoft.EventGrid'
    'Microsoft.EventHub'
    'Microsoft.Insights'
    'Microsoft.KeyVault'
    'Microsoft.ManagedIdentity'
    'Microsoft.OperationalInsights'
    'Microsoft.Storage'
    'Microsoft.Consumption'
    'Microsoft.Web'
)
$missingProviders = @(
    foreach ($providerNamespace in $providerNamespaces) {
        $registrationState = & az provider show `
            --namespace $providerNamespace `
            --query registrationState `
            --output tsv
        if ($LASTEXITCODE -ne 0) {
            throw "Could not read the registration state for $providerNamespace."
        }
        if ($registrationState -ne 'Registered') {
            $providerNamespace
        }
    }
)

$subscriptionExportsJson = @(& az rest `
    --only-show-errors `
    --method GET `
    --uri "https://management.azure.com${subscriptionScope}/providers/Microsoft.CostManagement/exports?api-version=2025-03-01" `
    --output json 2>$null)
if ($LASTEXITCODE -eq 0 -and $subscriptionExportsJson) {
    $unexpectedExports = @(
        (($subscriptionExportsJson -join "`n" | ConvertFrom-Json).value) |
            Where-Object { $_.name -like 'aiobs-hub-*' }
    )
    if ($unexpectedExports.Count -gt 0) {
        throw 'A managed export with this demo naming convention exists at subscription scope. Remove it before deployment.'
    }
}

$conflictingExportsJson = @(& az graph query `
    --subscriptions $subscriptionId `
    --graph-query "resources | where type =~ 'microsoft.costmanagement/exports' | where name startswith 'aiobs-hub-' | project id" `
    --query data `
    --output json 2>$null)
if ($LASTEXITCODE -eq 0 -and $conflictingExportsJson) {
    $conflictingExports = @(($conflictingExportsJson -join "`n" | ConvertFrom-Json))
    if ($conflictingExports.Count -gt 0) {
        $allowedPrefix = if ($resourceGroupName) {
            "$subscriptionScope/resourceGroups/$resourceGroupName/"
        }
        else {
            ''
        }
        $outsideExports = @(
            $conflictingExports |
                Where-Object { -not $allowedPrefix -or $_.id -notlike "$allowedPrefix*" }
        )
        if ($outsideExports.Count -gt 0) {
            throw 'A demo managed export exists outside the one allowed resource-group scope.'
        }
    }
}

$permissionsJson = & az rest `
  --only-show-errors `
  --method GET `
  --uri "https://management.azure.com$subscriptionScope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" `
  --output json
if ($LASTEXITCODE -ne 0 -or -not $permissionsJson) {
  throw 'Could not evaluate the deployment principal permissions at subscription scope.'
}

$permissions = @(($permissionsJson -join "`n" | ConvertFrom-Json).value)
$requiredActions = @(
  'Microsoft.Resources/deployments/write'
  'Microsoft.Resources/subscriptions/resourceGroups/write'
  'Microsoft.Authorization/roleAssignments/write'
  'Microsoft.Authorization/roleAssignments/delete'
  'Microsoft.CostManagement/exports/write'
  'Microsoft.CostManagement/exports/delete'
  'Microsoft.Consumption/budgets/write'
  'Microsoft.DataFactory/factories/write'
  'Microsoft.DataFactory/factories/read'
  'Microsoft.DataFactory/factories/pipelines/createrun/action'
  'Microsoft.DataFactory/factories/pipelineruns/read'
  'Microsoft.Resources/deploymentScripts/read'
  'Microsoft.Resources/deploymentScripts/write'
  'Microsoft.Resources/deploymentScripts/delete'
  'Microsoft.Web/sites/config/write'
)
$missingActions = @($requiredActions | Where-Object { -not (Test-AzurePermission $permissions $_) })
if ($missingActions.Count -gt 0) {
  $formattedActions = $missingActions | ForEach-Object { "  - $_" }
  throw @"
The deployment principal lacks required subscription permissions:
$($formattedActions -join "`n")
Assign Owner, or assign Contributor plus Role Based Access Control Administrator, at subscription scope.
Subscription-level role assignment access is required for the processor Cost Management Reader role.
"@
}

if ($missingProviders.Count -gt 0) {
  $formattedProviders = $missingProviders | ForEach-Object { "  - $_" }
  throw @"
The required Azure resource providers are not registered:
$($formattedProviders -join "`n")
Register the missing providers before deployment. The provider-registration and legacy-resource checks in this hook are read-only and will not change Azure state.
"@
}

$resourceGroupExists = if ($resourceGroupName) {
  (& az group exists --subscription $subscriptionId --name $resourceGroupName).Trim() -eq 'true'
}
else {
  $false
}
if ($resourceGroupExists) {
  $mainResourceGroupId = "$subscriptionScope/resourceGroups/$resourceGroupName"
  $resourceInventoryJson = @(& az resource list `
    --subscription $subscriptionId `
    --resource-group $resourceGroupName `
    --output json)
  if ($LASTEXITCODE -ne 0) {
    throw "Could not inspect legacy resources in $resourceGroupName."
  }

  $resourceInventory = @(($resourceInventoryJson -join "`n" | ConvertFrom-Json))
  $blockingLegacyResources = [System.Collections.Generic.List[string]]::new()
  $legacyExportId = "$mainResourceGroupId/providers/Microsoft.CostManagement/exports/ai-observability-demo-daily-actual-cost"
  if (Test-AzureResourceExists -ResourceId $legacyExportId -ApiVersion '2025-03-01') {
    $blockingLegacyResources.Add("Cost Management export: $legacyExportId")
  }

  foreach ($legacyResource in @(
    $resourceInventory |
      Where-Object {
        ($_.type -ieq 'Microsoft.Logic/workflows' -and $_.name -like 'ai-observability-demo-finops-*') -or
        ($_.type -ieq 'Microsoft.Insights/dataCollectionEndpoints' -and $_.name -like 'ai-observability-demo-dce-*') -or
        ($_.type -ieq 'Microsoft.Insights/dataCollectionRules' -and $_.name -like 'ai-observability-demo-dcr-*') -or
        ($_.type -ieq 'Microsoft.Storage/storageAccounts' -and $_.name -like 'aiobservabilityst*')
      }
  )) {
    $blockingLegacyResources.Add("$($legacyResource.type): $($legacyResource.id)")
  }

  $workspaceIds = @(
    $resourceInventory |
      Where-Object { $_.type -ieq 'Microsoft.OperationalInsights/workspaces' } |
      Select-Object -ExpandProperty id
  )
  foreach ($workspaceId in $workspaceIds) {
    foreach ($tableName in @(
      'AIObservabilityCostDaily_CL'
      'AIObservabilityFinOpsState_CL'
      'AIObservabilityResourceInventory_CL'
    )) {
      $tableResourceId = "$workspaceId/tables/$tableName"
      if (Test-AzureResourceExists -ResourceId $tableResourceId -ApiVersion '2023-09-01') {
        $blockingLegacyResources.Add("Log Analytics table: $tableResourceId")
      }
    }
  }

  if ($blockingLegacyResources.Count -gt 0) {
    $formattedResources = $blockingLegacyResources | ForEach-Object { "  - $_" }
    throw @"
Legacy billing resources from the previous design are still present:
$($formattedResources -join "`n")
Run .\demo-scripts\teardown.ps1 before the first redesign deployment. This preprovision hook will not delete existing billing state automatically.
If you need an in-place migration, stop and get explicit migration approval before changing these resources.
"@
  }
}

$deletedVaultName = if ($values['USAGE_KEY_VAULT_NAME']) {
    $values['USAGE_KEY_VAULT_NAME']
}
elseif ($values['AZURE_RESOURCE_SUFFIX']) {
    $candidateName = "aiobs-kv-$($values['AZURE_RESOURCE_SUFFIX'].Replace('-', '').ToLowerInvariant())"
    $candidateName.Substring(0, [Math]::Min(24, $candidateName.Length))
}
else {
    ''
}
$location = if ($values['AZURE_LOCATION']) { $values['AZURE_LOCATION'] } else { 'swedencentral' }
if ($deletedVaultName -and $resourceGroupName) {
  $deletedVaultJson = @(& az keyvault list-deleted `
    --subscription $subscriptionId `
    --query "[?name=='$deletedVaultName'] | [0].{name:name,location:properties.location}" `
    --output json 2>$null)
  $deletedVaultText = $deletedVaultJson -join "`n"
  if ($LASTEXITCODE -eq 0 -and $deletedVaultText -and $deletedVaultText.Trim() -ne 'null') {
    $deletedVault = $deletedVaultJson -join "`n" | ConvertFrom-Json
    $deletedVaultLocation = if ($deletedVault.location) { $deletedVault.location } else { $location }
    Write-Host "Recovering purge-protected Key Vault $deletedVaultName..."
    # Create/confirm the resource group without --tags so that existing environment-level
    # tags (for example, security-control tags applied by the subscription owner) are
    # preserved. Azure ARM leaves existing tags unchanged when --tags is omitted from
    # az group create.
    & az group create `
      --subscription $subscriptionId `
      --name $resourceGroupName `
      --location $location `
      --only-show-errors `
      --output none
    if ($LASTEXITCODE -ne 0) {
      throw "Could not create resource group $resourceGroupName for Key Vault recovery."
    }

    & az keyvault recover `
      --subscription $subscriptionId `
      --name $deletedVaultName `
      --resource-group $resourceGroupName `
      --location $deletedVaultLocation `
      --only-show-errors `
      --output none
    if ($LASTEXITCODE -ne 0) {
      throw "Could not recover purge-protected Key Vault $deletedVaultName."
    }
  }
}

# Preserve the existing budget start and end dates to avoid ARM rejecting start-date updates.
# The preprovision hook runs before azd provision so that BUDGET_START_DATE and BUDGET_END_DATE
# are set before main.bicep is deployed; main.parameters.json passes these through as parameters.
$budgetPeriod = Get-AzureBudgetPeriod -SubscriptionId $subscriptionId `
    -ResourceGroupName $resourceGroupName -BudgetName 'ai-observability-demo-monthly-budget'
$budgetStartDate = $budgetPeriod.StartDate
$budgetEndDate = $budgetPeriod.EndDate
Write-Host "Main budget period: $budgetStartDate to $budgetEndDate"

& azd env set BUDGET_START_DATE $budgetStartDate --cwd $repoRoot | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Could not store BUDGET_START_DATE in the azd environment.'
}
& azd env set BUDGET_END_DATE $budgetEndDate --cwd $repoRoot | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Could not store BUDGET_END_DATE in the azd environment.'
}

& (Join-Path $repoRoot 'scripts\verify-finops-release.ps1')

Write-Host 'Azure provider and permission preflight passed.' -ForegroundColor Green
