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

function Remove-ScopedRole {
    param(
        [Parameter(Mandatory = $true)][string] $PrincipalId,
        [Parameter(Mandatory = $true)][string] $RoleDefinitionId,
        [Parameter(Mandatory = $true)][string] $Scope
    )

    & az role assignment delete `
        --assignee-object-id $PrincipalId `
        --role $RoleDefinitionId `
        --scope $Scope `
        --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Could not remove role $RoleDefinitionId for principal $PrincipalId at $Scope."
    }
}

$values = Get-AzdEnvironmentValues
$subscriptionId = $values['AZURE_SUBSCRIPTION_ID']
if (-not $subscriptionId) {
    Write-Warning 'AZURE_SUBSCRIPTION_ID is unavailable. External FinOps cleanup cannot run.'
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
        & az role assignment delete --ids $assignmentId --only-show-errors 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Could not remove role assignment $assignmentId. The postdown hook will retry."
        }
    }
}

$functionPrincipalId = $values['USAGE_PROCESSOR_PRINCIPAL_ID']
if ($functionPrincipalId) {
    Remove-ScopedRole `
        -PrincipalId $functionPrincipalId `
        -RoleDefinitionId '72fafb9e-0641-4937-9268-a91bfd8191a3' `
        -Scope "/subscriptions/$subscriptionId"
}

$finOpsResourceGroupName = $values['FINOPS_RESOURCE_GROUP_NAME']
$dataFactoryPrincipalId = $values['FINOPS_DATA_FACTORY_PRINCIPAL_ID']
$finOpsGroupExists = $false
if ($finOpsResourceGroupName) {
    $finOpsGroupExists = (& az group exists --subscription $subscriptionId --name $finOpsResourceGroupName).Trim() -eq 'true'
}
if (-not $dataFactoryPrincipalId -and $finOpsGroupExists) {
    $dataFactoryPrincipalId = & az datafactory list `
        --subscription $subscriptionId `
        --resource-group $finOpsResourceGroupName `
        --query '[0].identity.principalId' `
        --output tsv 2>$null
}
$mainResourceGroupId = $values['MAIN_RESOURCE_GROUP_ID']
if (-not $mainResourceGroupId -and $values['AZURE_RESOURCE_GROUP']) {
    $mainResourceGroupId = "/subscriptions/$subscriptionId/resourceGroups/$($values['AZURE_RESOURCE_GROUP'])"
}
if ($dataFactoryPrincipalId -and $mainResourceGroupId) {
    Remove-ScopedRole `
        -PrincipalId $dataFactoryPrincipalId `
        -RoleDefinitionId '434105ed-43f6-45c7-a02f-909b2ba83430' `
        -Scope $mainResourceGroupId
}

$hubStorageAccountId = $values['FINOPS_HUB_STORAGE_ACCOUNT_ID']
if (-not $hubStorageAccountId -and $finOpsGroupExists) {
    $hubStorageAccountId = & az storage account list `
        --subscription $subscriptionId `
        --resource-group $finOpsResourceGroupName `
        --query '[?isHnsEnabled].id | [0]' `
        --output tsv 2>$null
}
if ($functionPrincipalId -and $hubStorageAccountId) {
    Remove-ScopedRole `
        -PrincipalId $functionPrincipalId `
        -RoleDefinitionId '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1' `
        -Scope "$hubStorageAccountId/blobServices/default/containers/ingestion"
}

if ($finOpsResourceGroupName) {
    if ($finOpsGroupExists) {
        Write-Host "Starting deletion of sibling FinOps resource group $finOpsResourceGroupName..."
        & az group delete `
            --subscription $subscriptionId `
            --name $finOpsResourceGroupName `
            --yes `
            --no-wait `
            --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Could not start deletion of FinOps resource group $finOpsResourceGroupName."
        }
    }
}

$keyVaultName = $values['USAGE_KEY_VAULT_NAME']
if ($keyVaultName) {
    Write-Host "Key Vault $keyVaultName has purge protection. Teardown will not purge its recoverable data."
}
