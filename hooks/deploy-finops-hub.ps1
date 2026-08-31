[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

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
        [Parameter(Mandatory = $true)][hashtable] $Values,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $processValue = [Environment]::GetEnvironmentVariable($Name)
    if ($processValue) {
        return $processValue
    }
    if ($Values.ContainsKey($Name) -and $Values[$Name]) {
        return $Values[$Name]
    }
    throw "$Name is not configured."
}

function New-StableGuid {
    param(
        [Parameter(Mandatory = $true)][string] $Value
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Value.ToLowerInvariant()))[0..15]
        $bytes[7] = ($bytes[7] -band 0x0f) -bor 0x50
        $bytes[8] = ($bytes[8] -band 0x3f) -bor 0x80
        return [Guid]::new([byte[]]$bytes).ToString()
    }
    finally {
        $sha256.Dispose()
    }
}

function Set-AzdValue {
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][string] $Value
    )

    & azd env set $Name $Value --cwd $repoRoot | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not save $Name in the azd environment."
    }
}

function Ensure-RoleAssignment {
    param(
        [Parameter(Mandatory = $true)][string] $PrincipalId,
        [Parameter(Mandatory = $true)][string] $RoleDefinitionId,
        [Parameter(Mandatory = $true)][string] $Scope,
        [Parameter(Mandatory = $true)][string] $Purpose
    )

    $assignmentName = New-StableGuid "$Scope|$PrincipalId|$RoleDefinitionId"
    $assignmentId = "$Scope/providers/Microsoft.Authorization/roleAssignments/$assignmentName"
    & az rest `
        --only-show-errors `
        --method GET `
        --uri "https://management.azure.com${assignmentId}?api-version=2022-04-01" `
        --output none 2>$null
    if ($LASTEXITCODE -eq 0) {
        return $assignmentId
    }

    for ($attempt = 1; $attempt -le 18; $attempt++) {
        $output = & az role assignment create `
            --only-show-errors `
            --name $assignmentName `
            --assignee-object-id $PrincipalId `
            --assignee-principal-type ServicePrincipal `
            --role $RoleDefinitionId `
            --scope $Scope `
            --output json 2>&1
        if ($LASTEXITCODE -eq 0) {
            return $assignmentId
        }
        if (($output -join "`n") -match 'RoleAssignmentExists') {
            return $assignmentId
        }

        if ($attempt -eq 18) {
            throw "Could not create the $Purpose role assignment: $($output -join "`n")"
        }
        Start-Sleep -Seconds 10
    }
}

function Invoke-FinOpsDeployment {
    param(
        [Parameter(Mandatory = $true)][bool] $EnableManagedExports,
        [Parameter(Mandatory = $true)][string] $DeploymentName
    )

    if (-not (Test-Path -LiteralPath $templateFile -PathType Leaf)) {
        throw 'The compiled FinOps hub template is unavailable.'
    }

    $parameters.parameters.enableManagedExports.value = $EnableManagedExports
    [System.IO.File]::WriteAllText(
        $parameterFile,
        ($parameters | ConvertTo-Json -Depth 20),
        [System.Text.UTF8Encoding]::new($false)
    )

    $output = & az deployment group create `
        --only-show-errors `
        --subscription $subscriptionId `
        --resource-group $finOpsResourceGroupName `
        --name $DeploymentName `
        --no-prompt `
        --template-file $templateFile `
        --parameters "@$parameterFile" `
        --query properties.outputs `
        --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "FinOps hub deployment '$DeploymentName' failed: $($output -join "`n")"
    }
    return ($output -join "`n" | ConvertFrom-Json)
}

$repoRoot = Split-Path -Parent $PSScriptRoot
& (Join-Path $repoRoot 'scripts\verify-finops-release.ps1')

$values = Get-AzdEnvironmentValues
$subscriptionId = Get-RequiredValue $values 'AZURE_SUBSCRIPTION_ID'
$mainResourceGroupName = Get-RequiredValue $values 'AZURE_RESOURCE_GROUP'
$mainResourceGroupId = Get-RequiredValue $values 'MAIN_RESOURCE_GROUP_ID'
$finOpsResourceGroupName = Get-RequiredValue $values 'FINOPS_RESOURCE_GROUP_NAME'
$finOpsHubName = Get-RequiredValue $values 'FINOPS_HUB_NAME'
$finOpsLocation = Get-RequiredValue $values 'FINOPS_LOCATION'
$functionAppName = Get-RequiredValue $values 'USAGE_PROCESSOR_FUNCTION_NAME'
$functionPrincipalId = Get-RequiredValue $values 'USAGE_PROCESSOR_PRINCIPAL_ID'
$functionIdentityClientId = Get-RequiredValue $values 'USAGE_PROCESSOR_IDENTITY_CLIENT_ID'
$budgetAmount = [int](Get-RequiredValue $values 'FINOPS_SUPPORT_BUDGET_AMOUNT')
$budgetStartDate = Get-RequiredValue $values 'FINOPS_BUDGET_START_DATE'
$notificationEmailList = if ($values.ContainsKey('FINOPS_NOTIFICATION_EMAILS')) {
    [string]$values['FINOPS_NOTIFICATION_EMAILS']
}
else {
    ''
}

$expectedResourceGroupId = "/subscriptions/$subscriptionId/resourceGroups/$mainResourceGroupName"
if ($mainResourceGroupId -ine $expectedResourceGroupId) {
    throw "MAIN_RESOURCE_GROUP_ID must equal $expectedResourceGroupId. Other Cost Management scopes are not allowed."
}

$notificationEmails = @()
if ($notificationEmailList) {
    $notificationEmails = @($notificationEmailList -split ';' | Where-Object { $_ })
}

& az account set --subscription $subscriptionId --only-show-errors
if ($LASTEXITCODE -ne 0) {
    throw "Could not select Azure subscription $subscriptionId."
}

& az group create `
    --subscription $subscriptionId `
    --name $finOpsResourceGroupName `
    --location $finOpsLocation `
    --tags workload=ai-observability component=finops-hub `
    --only-show-errors `
    --output none
if ($LASTEXITCODE -ne 0) {
    throw "Could not create the FinOps support resource group $finOpsResourceGroupName."
}

$workingDirectory = Join-Path $repoRoot '.azure'
New-Item -ItemType Directory -Force -Path $workingDirectory | Out-Null
$parameterFile = Join-Path $workingDirectory "finops-hub-$PID.parameters.json"
$templateFile = Join-Path $workingDirectory "finops-hub-$PID.json"
$wrapperPath = Join-Path $repoRoot 'infra\modules\finops-hub-wrapper.bicep'
$parameters = @{
    '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters = @{
        hubName = @{ value = $finOpsHubName }
        mainResourceGroupName = @{ value = $mainResourceGroupName }
        location = @{ value = $finOpsLocation }
        enableManagedExports = @{ value = $false }
        monthlyBudgetAmount = @{ value = $budgetAmount }
        notificationEmails = @{ value = $notificationEmails }
        budgetStartDate = @{ value = $budgetStartDate }
        tags = @{
            value = @{
                env = 'demo'
                owner = 'ai-observability'
                workload = 'ai-observability'
                component = 'finops-hub'
            }
        }
    }
}

try {
    $bicepExecutable = Join-Path $env:USERPROFILE '.azure\bin\bicep.exe'
    if (-not (Test-Path -LiteralPath $bicepExecutable -PathType Leaf)) {
        & az bicep install | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $bicepExecutable -PathType Leaf)) {
            throw 'Could not locate the Azure CLI Bicep executable.'
        }
    }
    & $bicepExecutable build $wrapperPath --outfile $templateFile
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not compile the vendored FinOps hub wrapper.'
    }

    Write-Host "Deploying FinOps hub foundation to $finOpsResourceGroupName..."
    $foundationOutputs = Invoke-FinOpsDeployment $false 'finops-hub-foundation'
    $dataFactoryPrincipalId = [string]$foundationOutputs.dataFactoryPrincipalId.value
    if (-not $dataFactoryPrincipalId) {
        throw 'The FinOps hub deployment did not return its Data Factory principal ID.'
    }

    $costManagementContributorRoleId = '434105ed-43f6-45c7-a02f-909b2ba83430'
    $dataFactoryCostAssignmentId = Ensure-RoleAssignment `
        -PrincipalId $dataFactoryPrincipalId `
        -RoleDefinitionId $costManagementContributorRoleId `
        -Scope $mainResourceGroupId `
        -Purpose 'Data Factory Cost Management Contributor'

    Write-Host "Enabling managed FOCUS exports for only $mainResourceGroupId..."
    $managedOutputs = Invoke-FinOpsDeployment $true 'finops-hub-managed-exports'
    if (-not [bool]$managedOutputs.managedExportsEnabled.value) {
        throw 'The final FinOps hub deployment did not enable managed exports.'
    }
    if ([string]$managedOutputs.monitoredResourceGroupId.value -ine $mainResourceGroupId) {
        throw 'The FinOps hub returned a monitored scope that differs from the main resource group.'
    }

    $resourceGroupExportsJson = @()
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $resourceGroupExportsJson = @(& az rest `
            --only-show-errors `
            --method GET `
            --uri "https://management.azure.com${mainResourceGroupId}/providers/Microsoft.CostManagement/exports?api-version=2025-03-01" `
            --output json)
        if ($LASTEXITCODE -eq 0) {
            break
        }
        if ($attempt -eq 12) {
            throw 'Could not verify managed exports at the main resource-group scope.'
        }
        Start-Sleep -Seconds 10
    }
    $hubExports = @()
    for ($attempt = 1; $attempt -le 18; $attempt++) {
        $resourceGroupExports = @(($resourceGroupExportsJson -join "`n" | ConvertFrom-Json).value)
        $hubExports = @(
            $resourceGroupExports |
                Where-Object { $_.name -like "$finOpsHubName-*" }
        )
        if ($hubExports.Count -ge 2) {
            break
        }
        Start-Sleep -Seconds 10
        $resourceGroupExportsJson = @(& az rest `
            --only-show-errors `
            --method GET `
            --uri "https://management.azure.com${mainResourceGroupId}/providers/Microsoft.CostManagement/exports?api-version=2025-03-01" `
            --output json)
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not poll managed exports at the main resource-group scope.'
        }
    }
    $focusExports = @(
        $hubExports |
            Where-Object { $_.properties.definition.type -ieq 'FocusCost' }
    )
    $dailyFocusExports = @(
        $focusExports |
            Where-Object { $_.properties.schedule.recurrence -eq 'Daily' }
    )
    $monthlyFocusExports = @(
        $focusExports |
            Where-Object { $_.properties.schedule.recurrence -eq 'Monthly' }
    )
    if ($dailyFocusExports.Count -ne 1 -or $monthlyFocusExports.Count -ne 1) {
        throw 'Expected exactly one daily and one monthly FOCUS export at the main resource-group scope.'
    }
    $invalidFocusExports = @(
        $focusExports |
            Where-Object {
                $_.properties.format -ine 'Parquet' -or
                $_.properties.compressionMode -ine 'Snappy' -or
                $_.properties.definition.dataSet.configuration.dataVersion -notlike '1.2*'
            }
    )
    if ($invalidFocusExports.Count -gt 0) {
        throw 'Managed FOCUS exports must use the v1.2 schema, Parquet, and Snappy compression.'
    }
    foreach ($export in $focusExports) {
        & az rest `
            --only-show-errors `
            --method POST `
            --uri "https://management.azure.com$($export.id)/run?api-version=2025-03-01" `
            --output none
        if ($LASTEXITCODE -ne 0) {
            throw "Could not start managed FOCUS export $($export.name)."
        }
    }
    if (@($hubExports | Where-Object { $_.id -notlike "$mainResourceGroupId/*" }).Count -gt 0) {
        throw 'A managed export resolved outside the allowlisted main resource group.'
    }

    $hubStorageAccountId = [string]$managedOutputs.hubStorageAccountId.value
    $hubStorageAccountName = [string]$managedOutputs.hubStorageAccountName.value
    $costManagementReaderRoleId = '72fafb9e-0641-4937-9268-a91bfd8191a3'
    $storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
    $subscriptionScope = "/subscriptions/$subscriptionId"
    $hubIngestionContainerScope = "$hubStorageAccountId/blobServices/default/containers/ingestion"
    $containerProvisioned = $false
    for ($attempt = 1; $attempt -le 30; $attempt++) {
        & az rest `
            --only-show-errors `
            --method GET `
            --uri "https://management.azure.com${hubIngestionContainerScope}?api-version=2023-05-01" `
            --output none 2>$null
        if ($LASTEXITCODE -eq 0) {
            $containerProvisioned = $true
            break
        }
        Start-Sleep -Seconds 10
    }
    if (-not $containerProvisioned) {
        throw 'The FinOps hub ingestion container was not ready for processor access.'
    }

    $functionCostAssignmentId = Ensure-RoleAssignment `
        -PrincipalId $functionPrincipalId `
        -RoleDefinitionId $costManagementReaderRoleId `
        -Scope $subscriptionScope `
        -Purpose 'processor Cost Management Reader'
    $functionHubStorageAssignmentId = Ensure-RoleAssignment `
        -PrincipalId $functionPrincipalId `
        -RoleDefinitionId $storageBlobDataReaderRoleId `
        -Scope $hubIngestionContainerScope `
        -Purpose 'processor FinOps storage Blob Data Reader'

    & az functionapp config appsettings set `
        --only-show-errors `
        --subscription $subscriptionId `
        --resource-group $mainResourceGroupName `
        --name $functionAppName `
        --settings `
        "FINOPS_HUB_STORAGE_ACCOUNT_NAME=$hubStorageAccountName" `
        "FINOPS_HUB_STORAGE_BLOB_ENDPOINT=https://$hubStorageAccountName.blob.core.windows.net/" `
        "FINOPS_HUB_STORAGE_DFS_ENDPOINT=https://$hubStorageAccountName.dfs.core.windows.net/" `
        'FINOPS_HUB_INGESTION_CONTAINER=ingestion' `
        'FINOPS_HUB_STORAGE_CREDENTIAL=managedidentity' `
        "FINOPS_HUB_STORAGE_CLIENT_ID=$functionIdentityClientId" `
        "WORKLOAD_RESOURCE_GROUP_ID=$mainResourceGroupId" `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not configure the Function App with the FinOps hub storage endpoint.'
    }

    Set-AzdValue 'FINOPS_DATA_FACTORY_PRINCIPAL_ID' $dataFactoryPrincipalId
    Set-AzdValue 'FINOPS_HUB_STORAGE_ACCOUNT_ID' $hubStorageAccountId
    Set-AzdValue 'FINOPS_HUB_STORAGE_ACCOUNT_NAME' $hubStorageAccountName
    Set-AzdValue 'FINOPS_DATA_FACTORY_COST_ROLE_ASSIGNMENT_ID' $dataFactoryCostAssignmentId
    Set-AzdValue 'USAGE_PROCESSOR_COST_ROLE_ASSIGNMENT_ID' $functionCostAssignmentId
    Set-AzdValue 'USAGE_PROCESSOR_FINOPS_STORAGE_ROLE_ASSIGNMENT_ID' $functionHubStorageAssignmentId
}
finally {
    Remove-Item -LiteralPath $parameterFile -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $templateFile -Force -ErrorAction SilentlyContinue
}

Write-Host 'FinOps hub v14 and managed resource-group exports are configured.' -ForegroundColor Green
