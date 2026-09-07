$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
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

# Ensure a stable resource suffix exists before any name-dependent steps.
$resourceSuffix = $values['AZURE_RESOURCE_SUFFIX']
if (-not $resourceSuffix) {
    $suffixBytes = [byte[]]::new(3)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($suffixBytes)
    $resourceSuffix = [BitConverter]::ToString($suffixBytes).Replace('-', '').ToLowerInvariant()
    & azd env set AZURE_RESOURCE_SUFFIX $resourceSuffix --cwd $repoRoot | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not store AZURE_RESOURCE_SUFFIX in the azd environment.'
    }
    Write-Host "Generated resource suffix: $resourceSuffix"
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
$budgetStartDate = ''
$budgetEndDate = ''
if ($resourceGroupName) {
    $mainRgId = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName"
    $budgetUri = "https://management.azure.com${mainRgId}/providers/Microsoft.Consumption/budgets/ai-observability-demo-monthly-budget?api-version=2024-08-01"
    $budgetOutput = & az rest `
        --only-show-errors `
        --method GET `
        --uri $budgetUri `
        --output json 2>&1
    if ($LASTEXITCODE -eq 0 -and $budgetOutput) {
        $existingBudget = ($budgetOutput -join "`n" | ConvertFrom-Json)
        if ($existingBudget.properties.timePeriod.startDate) {
            $budgetStartDate = ($existingBudget.properties.timePeriod.startDate -replace 'T.*$', '')
        }
        if ($existingBudget.properties.timePeriod.endDate) {
            $budgetEndDate = ($existingBudget.properties.timePeriod.endDate -replace 'T.*$', '')
        }
        Write-Host "Preserved existing budget period: $budgetStartDate – $budgetEndDate"
    } elseif (($budgetOutput -join "`n") -match 'ResourceNotFound|BudgetNotFound|does not exist|NotFound|404') {
        # Budget does not exist yet; choose the first day of the current UTC month.
        $now = [System.DateTime]::UtcNow
        $budgetStartDate = (New-Object System.DateTime $now.Year, $now.Month, 1, 0, 0, 0, ([System.DateTimeKind]::Utc)).ToString('yyyy-MM-dd')
        Write-Host "Budget not found; using start date: $budgetStartDate"
    } elseif (($budgetOutput -join "`n") -match 'AuthorizationFailed|Forbidden|does not have.*permission|403') {
        throw "Could not read the existing budget to preserve its start date (authorization denied): $($budgetOutput -join "`n")"
    } elseif ($budgetOutput) {
        throw "Could not read the existing budget to preserve its start date: $($budgetOutput -join "`n")"
    }
}
if (-not $budgetStartDate) {
    $now = [System.DateTime]::UtcNow
    $budgetStartDate = (New-Object System.DateTime $now.Year, $now.Month, 1, 0, 0, 0, ([System.DateTimeKind]::Utc)).ToString('yyyy-MM-dd')
}

& azd env set BUDGET_START_DATE $budgetStartDate --cwd $repoRoot | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Could not store BUDGET_START_DATE in the azd environment.'
}
& azd env set BUDGET_END_DATE $budgetEndDate --cwd $repoRoot | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Could not store BUDGET_END_DATE in the azd environment.'
}

# Bootstrap the HMAC secret before main provision so that APIM finds the secret on first deploy.
# A small foundation Bicep creates (or confirms) the Key Vault and grants the deploying principal
# a narrowly scoped Key Vault Secrets Officer role. The secret is created only after a confirmed
# 404; an existing secret is never rotated. The temporary role is removed immediately after.
if ($resourceGroupName) {
    $cleanSuffix = $resourceSuffix.ToLowerInvariant() -replace '-', ''
    $kvNameCandidate = "aiobs-kv-$cleanSuffix"
    $kvName = $kvNameCandidate.Substring(0, [Math]::Min(24, $kvNameCandidate.Length))
    $hmacSecretName = 'usage-hmac-key'

    $deployingPrincipalId = $values['AZURE_PRINCIPAL_ID']
    if (-not $deployingPrincipalId) {
        throw 'AZURE_PRINCIPAL_ID is not set. The HMAC bootstrap requires the deployment principal ID.'
    }

    $accountTypeOutput = (& az account show --only-show-errors --query 'user.type' --output tsv 2>&1)
    $deployingPrincipalType = if ($LASTEXITCODE -eq 0 -and ($accountTypeOutput -join '').Trim() -eq 'user') {
        'User'
    } else {
        'ServicePrincipal'
    }

    $bicepExe = Join-Path $env:USERPROFILE '.azure\bin\bicep.exe'
    if (-not (Test-Path -LiteralPath $bicepExe -PathType Leaf)) {
        throw "Bicep CLI not found at $bicepExe. Run 'az bicep install' first."
    }

    # Create the resource group now so the foundation Bicep can deploy into it.
    & az group create `
        --subscription $subscriptionId `
        --name $resourceGroupName `
        --location $location `
        --only-show-errors `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create resource group $resourceGroupName for HMAC bootstrap."
    }

    $workingDirectory = Join-Path $repoRoot '.azure'
    New-Item -ItemType Directory -Force -Path $workingDirectory | Out-Null
    $bootstrapTemplate = Join-Path $workingDirectory "hmac-kv-prep-$PID.json"
    $bootstrapBicepPath = Join-Path $repoRoot 'infra\bootstrap\hmac-kv-prep.bicep'
    $bootstrapRoleId = $null
    try {
        $buildOutput = & $bicepExe build $bootstrapBicepPath --outfile $bootstrapTemplate 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Could not compile the HMAC bootstrap template: $($buildOutput -join "`n")"
        }

        $bootstrapOutputJson = & az deployment group create `
            --only-show-errors `
            --subscription $subscriptionId `
            --resource-group $resourceGroupName `
            --name 'hmac-kv-bootstrap' `
            --template-file $bootstrapTemplate `
            --parameters `
                "keyVaultName=$kvName" `
                "location=$location" `
                "deployingPrincipalId=$deployingPrincipalId" `
                "deployingPrincipalType=$deployingPrincipalType" `
            --query 'properties.outputs' `
            --output json 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "HMAC bootstrap deployment failed: $($bootstrapOutputJson -join "`n")"
        }

        $bootstrapOutputs = ($bootstrapOutputJson -join "`n" | ConvertFrom-Json)
        $bootstrapRoleId = [string]$bootstrapOutputs.bootstrapRoleAssignmentId.value

        # Retry loop: waits for RBAC propagation, then checks or creates the secret.
        # Creates only on a confirmed 404; does not rotate an existing secret.
        # Fails on authorization errors rather than silently falling back.
        $secretConfirmed = $false
        for ($attempt = 1; $attempt -le 30; $attempt++) {
            $checkOutput = & az keyvault secret show `
                --subscription $subscriptionId `
                --vault-name $kvName `
                --name $hmacSecretName `
                --only-show-errors `
                --output none 2>&1
            $checkMessage = ($checkOutput -join "`n")

            if ($LASTEXITCODE -eq 0) {
                Write-Host "HMAC bootstrap: $hmacSecretName already exists in $kvName."
                $secretConfirmed = $true
                break
            } elseif ($checkMessage -match 'SecretNotFound|ItemNotFound') {
                # Confirmed absent – create a cryptographically random 48-byte secret.
                $secretBytes = [byte[]]::new(48)
                [System.Security.Cryptography.RandomNumberGenerator]::Fill($secretBytes)
                $secretValue = [Convert]::ToBase64String($secretBytes)
                try {
                    $setOutput = & az keyvault secret set `
                        --subscription $subscriptionId `
                        --vault-name $kvName `
                        --name $hmacSecretName `
                        --value $secretValue `
                        --only-show-errors `
                        --output none 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        throw "Could not create $hmacSecretName in $kvName`: $($setOutput -join "`n")"
                    }
                } finally {
                    $secretValue = $null
                    [System.GC]::Collect()
                }
                Write-Host "HMAC bootstrap: created $hmacSecretName in $kvName."
                $secretConfirmed = $true
                break
            } elseif ($checkMessage -match 'Forbidden|Unauthorized|does not have|AKV403|403') {
                # Role assignment has not yet propagated; wait and retry.
                if ($attempt -lt 30) {
                    Start-Sleep -Seconds 10
                    continue
                }
                throw "HMAC bootstrap: access to $kvName was not granted after 5 minutes. Role propagation timed out."
            } else {
                throw "HMAC bootstrap: unexpected error checking $hmacSecretName in ${kvName}: $checkMessage"
            }
        }
        if (-not $secretConfirmed) {
            throw "HMAC bootstrap: could not verify or create $hmacSecretName in $kvName."
        }
    } finally {
        Remove-Item -LiteralPath $bootstrapTemplate -Force -ErrorAction SilentlyContinue
        # Remove the temporary Secrets Officer role immediately after the secret is confirmed.
        if ($bootstrapRoleId) {
            $removeOutput = & az role assignment delete `
                --only-show-errors `
                --ids $bootstrapRoleId 2>&1
            if ($LASTEXITCODE -ne 0 -and ($removeOutput -join "`n") -notmatch 'RoleAssignmentNotFound|could not be found') {
                Write-Warning "HMAC bootstrap: could not remove temporary role $bootstrapRoleId – $($removeOutput -join "`n")"
            } else {
                Write-Host 'HMAC bootstrap: removed temporary Key Vault Secrets Officer role.'
            }
        }
    }
}

& (Join-Path $repoRoot 'scripts\verify-finops-release.ps1')

Write-Host 'Azure provider and permission preflight passed.' -ForegroundColor Green
