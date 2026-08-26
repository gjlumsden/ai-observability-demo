$ErrorActionPreference = 'Stop'

Write-Host 'Checking Cost Management resource providers...'

$repoRoot = Split-Path -Parent $PSScriptRoot
$subscriptionLine = (azd env get-values --cwd $repoRoot) |
  Where-Object { $_ -like 'AZURE_SUBSCRIPTION_ID=*' } |
  Select-Object -First 1
if (-not $subscriptionLine) {
  throw 'AZURE_SUBSCRIPTION_ID is not set in the azd environment.'
}
$subscriptionId = ($subscriptionLine -replace '^AZURE_SUBSCRIPTION_ID=', '') -replace '^"', '' -replace '"$', ''
az account set --subscription $subscriptionId
if ($LASTEXITCODE -ne 0) {
  throw 'Could not select the Azure subscription.'
}

foreach ($providerNamespace in @(
  'Microsoft.CostManagement'
  'Microsoft.CostManagementExports'
)) {
  $registrationState = az provider show `
    --namespace $providerNamespace `
    --query registrationState `
    --output tsv

  if ($registrationState -ne 'Registered') {
    Write-Host "Registering $providerNamespace..."
    az provider register --namespace $providerNamespace --wait
    if ($LASTEXITCODE -ne 0) {
      throw "Could not register $providerNamespace."
    }
  }
}
