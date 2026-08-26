$ErrorActionPreference = 'Stop'

function Get-AzdEnvironmentValues {
    $values = @{}
    try {
        $output = azd env get-values 2>$null
        if ($LASTEXITCODE -eq 0 -and $output) {
            foreach ($line in $output) {
                if ($line -match '^\s*([^=]+)=(.*)\s*$') {
                    $values[$Matches[1].Trim()] = $Matches[2].Trim().Trim('"')
                }
            }
        }
    }
    catch {
        Write-Warning "Could not read azd environment values: $($_.Exception.Message)"
    }
    return $values
}

function Get-AzdValue {
    param(
        [Parameter(Mandatory = $true)][hashtable] $Values,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $environmentValue = [Environment]::GetEnvironmentVariable($Name)
    if ($environmentValue) {
        return $environmentValue
    }
    if ($Values.ContainsKey($Name) -and $Values[$Name]) {
        return $Values[$Name]
    }
    return $null
}

$azdValues = Get-AzdEnvironmentValues
$environmentName = Get-AzdValue $azdValues 'AZURE_ENV_NAME'
$subscriptionId = Get-AzdValue $azdValues 'AZURE_SUBSCRIPTION_ID'
$resourceGroup = Get-AzdValue $azdValues 'AZURE_RESOURCE_GROUP'
$clientId = Get-AzdValue $azdValues 'ENTRA_CLIENT_ID'
$foundryAccounts = @()
$apimServices = @()

if ($subscriptionId -and $resourceGroup) {
    az account set --subscription $subscriptionId
    if ($LASTEXITCODE -ne 0) {
        throw "Could not select Azure subscription $subscriptionId."
    }

    $groupExists = (az group exists --name $resourceGroup --subscription $subscriptionId).Trim()
    if ($groupExists -eq 'true') {
        $foundryAccounts = @(
            az resource list `
                --subscription $subscriptionId `
                --resource-group $resourceGroup `
                --resource-type Microsoft.CognitiveServices/accounts `
                --query '[].{name:name,location:location}' `
                --output json |
                ConvertFrom-Json
        )
        $apimServices = @(
            az resource list `
                --subscription $subscriptionId `
                --resource-group $resourceGroup `
                --resource-type Microsoft.ApiManagement/service `
                --query '[].{name:name,location:location}' `
                --output json |
                ConvertFrom-Json
        )
    }
}

Write-Host "This will permanently delete the azd environment resources with:"
Write-Host "  azd down --force --purge"
if ($clientId) {
    Write-Host "It will also delete Entra app registration: $clientId"
}

$confirmation = Read-Host "Type 'delete ai observability demo' to continue"
if ($confirmation -ne 'delete ai observability demo') {
    Write-Host "Teardown cancelled."
    exit 0
}

azd down --force --purge
$downExitCode = $LASTEXITCODE
if ($downExitCode -ne 0) {
    Write-Error "azd down failed with exit code $downExitCode. The Entra app registration was not deleted."
    exit $downExitCode
}

if ($subscriptionId -and $resourceGroup) {
    $groupExists = (az group exists --name $resourceGroup --subscription $subscriptionId).Trim()
    if ($groupExists -eq 'true') {
        Write-Host "azd left resource group $resourceGroup. Deleting it directly."
        az group delete `
            --subscription $subscriptionId `
            --name $resourceGroup `
            --yes
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Could not delete resource group $resourceGroup."
            exit $LASTEXITCODE
        }
    }
}

$deletedFoundryAccounts = @(az cognitiveservices account list-deleted --output json | ConvertFrom-Json)
foreach ($account in $foundryAccounts) {
    if ($deletedFoundryAccounts.name -contains $account.name) {
        Write-Host "Purging Foundry account $($account.name)"
        az cognitiveservices account purge `
            --name $account.name `
            --resource-group $resourceGroup `
            --location $account.location `
            --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Could not purge Foundry account $($account.name)."
            exit $LASTEXITCODE
        }
    }
}

$deletedApimServices = @(az apim deletedservice list --output json | ConvertFrom-Json)
foreach ($service in $apimServices) {
    if ($deletedApimServices.name -contains $service.name) {
        Write-Host "Purging API Management service $($service.name)"
        az apim deletedservice purge `
            --service-name $service.name `
            --location $service.location `
            --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Could not purge API Management service $($service.name)."
            exit $LASTEXITCODE
        }
    }
}

if ($clientId) {
    Write-Host "Deleting Entra app registration $clientId"
    az ad app delete --id $clientId --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Azure resources were deleted, but the Entra app registration $clientId remains."
        exit $LASTEXITCODE
    }
}
else {
    Write-Warning "Azure resources were deleted, but ENTRA_CLIENT_ID was not available. Check Entra ID for an orphaned AI Observability Demo app registration."
    exit 2
}

if ($environmentName) {
    $localEnvironments = @(azd env list --output json | ConvertFrom-Json)
    if ($localEnvironments.Name -contains $environmentName) {
        azd env remove $environmentName --force --no-prompt
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Cloud cleanup completed, but local azd environment $environmentName remains."
            exit $LASTEXITCODE
        }
    }
}

Write-Host 'Complete cleanup finished.'
exit 0
