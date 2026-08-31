$ErrorActionPreference = 'Stop'

function Get-AzdEnvironmentValues {
    $values = @{}
    $output = azd env get-values 2>$null
    if ($LASTEXITCODE -eq 0) {
        foreach ($line in $output) {
            if ($line -match '^\s*([^=]+)=(.*)\s*$') {
                $values[$Matches[1].Trim()] = $Matches[2].Trim().Trim('"')
            }
        }
    }
    return $values
}

$values = Get-AzdEnvironmentValues
$subscriptionId = $values['AZURE_SUBSCRIPTION_ID']
if (-not $subscriptionId) {
    Write-Warning 'AZURE_SUBSCRIPTION_ID is unavailable. Verify external role assignments and the FinOps resource group manually.'
    return
}

& az account set --subscription $subscriptionId --only-show-errors
if ($LASTEXITCODE -ne 0) {
    throw "Could not select Azure subscription $subscriptionId."
}

foreach ($name in @(
    'FINOPS_DATA_FACTORY_COST_ROLE_ASSIGNMENT_ID'
    'USAGE_PROCESSOR_COST_ROLE_ASSIGNMENT_ID'
    'USAGE_PROCESSOR_FINOPS_STORAGE_ROLE_ASSIGNMENT_ID'
)) {
    $assignmentId = $values[$name]
    if ($assignmentId) {
        $assignmentExists = $false
        & az rest `
            --only-show-errors `
            --method GET `
            --uri "https://management.azure.com${assignmentId}?api-version=2022-04-01" `
            --output none 2>$null
        $assignmentExists = $LASTEXITCODE -eq 0
        if (-not $assignmentExists) {
            continue
        }
        & az role assignment delete --ids $assignmentId --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not remove external role assignment: $assignmentId"
        }
    }
}

$functionPrincipalId = $values['USAGE_PROCESSOR_PRINCIPAL_ID']
if ($functionPrincipalId) {
    $remainingFunctionCostAssignments = @(& az role assignment list `
        --assignee-object-id $functionPrincipalId `
        --role '72fafb9e-0641-4937-9268-a91bfd8191a3' `
        --scope "/subscriptions/$subscriptionId" `
        --query '[].id' `
        --output tsv 2>$null)
    $remainingFunctionCostAssignments = @($remainingFunctionCostAssignments | Where-Object { $_ })
    if ($LASTEXITCODE -eq 0 -and -not $remainingFunctionCostAssignments) {
        $functionPrincipalId = $null
    }
}
if ($functionPrincipalId) {
    & az role assignment delete `
        --assignee-object-id $functionPrincipalId `
        --role '72fafb9e-0641-4937-9268-a91bfd8191a3' `
        --scope "/subscriptions/$subscriptionId" `
        --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not remove the processor Cost Management Reader assignment.'
    }
}

$finOpsResourceGroupName = $values['FINOPS_RESOURCE_GROUP_NAME']
if ($finOpsResourceGroupName) {
    $exists = (& az group exists --subscription $subscriptionId --name $finOpsResourceGroupName).Trim()
    if ($exists -eq 'true') {
        & az group delete `
            --subscription $subscriptionId `
            --name $finOpsResourceGroupName `
            --yes `
            --no-wait `
            --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not restart deletion of FinOps resource group $finOpsResourceGroupName."
        }

        & az group wait `
            --subscription $subscriptionId `
            --name $finOpsResourceGroupName `
            --deleted `
            --interval 10 `
            --timeout 1800 `
            --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "The sibling FinOps resource group still exists: $finOpsResourceGroupName"
        }
    }
}

$mainResourceGroupName = $values['AZURE_RESOURCE_GROUP']
if ($mainResourceGroupName) {
    $mainGroupExists = (& az group exists --subscription $subscriptionId --name $mainResourceGroupName).Trim()
    if ($mainGroupExists -eq 'true') {
        Write-Host "Deleting remaining main resource group $mainResourceGroupName..."
        & az group delete `
            --subscription $subscriptionId `
            --name $mainResourceGroupName `
            --yes `
            --no-wait `
            --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Could not restart deletion of main resource group $mainResourceGroupName."
        }
        & az group wait `
            --subscription $subscriptionId `
            --name $mainResourceGroupName `
            --deleted `
            --interval 10 `
            --timeout 1800 `
            --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "The main demo resource group still exists: $mainResourceGroupName"
        }
    }
}

$foundryName = $values['FOUNDRY_NAME']
if ($foundryName -and $mainResourceGroupName) {
    $deletedFoundryRecord = @(& az cognitiveservices account list-deleted `
        --subscription $subscriptionId `
        --query "[?name=='$foundryName'] | [0].{name:name,location:location}" `
        --output json 2>$null)
    $deletedFoundry = if ($LASTEXITCODE -eq 0 -and $deletedFoundryRecord) {
        $deletedFoundryRecord -join "`n" | ConvertFrom-Json
    }
    else {
        $null
    }
    if ($deletedFoundry) {
        & az cognitiveservices account purge `
            --subscription $subscriptionId `
            --name $foundryName `
            --resource-group $mainResourceGroupName `
            --location $deletedFoundry.location `
            --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not purge deleted Foundry account $foundryName."
        }
    }
}

$apimName = $values['APIM_NAME']
if ($apimName) {
    $deletedApimRecord = @(& az apim deletedservice list `
        --subscription $subscriptionId `
        --query "[?name=='$apimName'] | [0].{name:name,location:location}" `
        --output json 2>$null)
    $deletedApim = if ($LASTEXITCODE -eq 0 -and $deletedApimRecord) {
        $deletedApimRecord -join "`n" | ConvertFrom-Json
    }
    else {
        $null
    }
    if ($deletedApim) {
        & az apim deletedservice purge `
            --subscription $subscriptionId `
            --service-name $apimName `
            --location $deletedApim.location `
            --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "Could not purge deleted API Management service $apimName."
        }
    }
}

$clientId = $values['ENTRA_CLIENT_ID']
if ($clientId) {
    & az ad app delete --id $clientId --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not delete Entra app registration $clientId."
    }
}
else {
    Write-Warning 'ENTRA_CLIENT_ID is unavailable. Check Microsoft Entra ID for an orphaned demo app registration.'
}

$keyVaultName = $values['USAGE_KEY_VAULT_NAME']
if ($keyVaultName) {
    $deletedVaultJson = @(& az keyvault list-deleted `
        --subscription $subscriptionId `
        --query "[?name=='$keyVaultName'] | [0].{name:name,scheduledPurgeDate:properties.scheduledPurgeDate}" `
        --output json 2>$null)
    $deletedVaultText = $deletedVaultJson -join "`n"
    if ($LASTEXITCODE -eq 0 -and $deletedVaultText -and $deletedVaultText.Trim() -ne 'null') {
        $deletedVault = $deletedVaultJson -join "`n" | ConvertFrom-Json
        Write-Warning "Key Vault $($deletedVault.name) remains recoverable because purge protection is enabled. Scheduled purge: $($deletedVault.scheduledPurgeDate)."
    }
}

Write-Host 'Active Azure resources and external role assignments were removed.' -ForegroundColor Green
