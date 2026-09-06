[CmdletBinding()]
param(
    [switch] $DeleteEntraApplication
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot

function Get-AzdEnvironmentValues {
    $values = @{}
    try {
        $output = azd env get-values --cwd $repoRoot 2>$null
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
$clientId = Get-AzdValue $azdValues 'ENTRA_CLIENT_ID'
$approveEntraDeletion = $false

Write-Host 'This will permanently delete the Azure resources for the active azd environment with:'
Write-Host '  azd down --force --purge'
Write-Host 'azd down deletes Azure resources only. It keeps the local .azure environment files.'
if ($DeleteEntraApplication -and $clientId) {
    Write-Warning "Approved full cleanup will also delete Entra app registration: $clientId"
}
elseif ($clientId) {
    Write-Host "The Entra app registration will be retained for reuse: $clientId"
    Write-Host 'Use -DeleteEntraApplication only after explicit approval for full cleanup.'
}
else {
    Write-Host 'No Entra app registration is recorded in the active azd environment.'
}
Write-Host 'The postdown hook will delete the sibling FinOps resource group and external role assignments.'
Write-Host 'The purge-protected Key Vault will remain recoverable until its scheduled purge date.'

$confirmation = Read-Host "Type 'delete ai observability demo' to continue"
if ($confirmation -ne 'delete ai observability demo') {
    Write-Host 'Teardown cancelled.'
    exit 0
}

if ($DeleteEntraApplication -and $clientId) {
    $entraConfirmation = Read-Host "Type 'delete Entra app registration' to also delete the demo Entra app registration"
    if ($entraConfirmation -eq 'delete Entra app registration') {
        $approveEntraDeletion = $true
    }
    else {
        Write-Host 'Entra app deletion was not approved. The app registration will be retained.'
    }
}

$previousDeleteFlag = [Environment]::GetEnvironmentVariable('AI_OBSERVABILITY_DELETE_ENTRA_APP')
try {
    if ($approveEntraDeletion) {
        $env:AI_OBSERVABILITY_DELETE_ENTRA_APP = 'true'
    }
    else {
        Remove-Item Env:\AI_OBSERVABILITY_DELETE_ENTRA_APP -ErrorAction SilentlyContinue
    }

    azd down --cwd $repoRoot --force --purge
    $downExitCode = $LASTEXITCODE
    if ($downExitCode -ne 0) {
        Write-Error "azd down failed with exit code $downExitCode."
        exit $downExitCode
    }

    if ($approveEntraDeletion) {
        azd env set ENTRA_CLIENT_ID '' --cwd $repoRoot | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not clear the deleted ENTRA_CLIENT_ID from the local azd environment.'
        }
    }
}
finally {
    if ($null -eq $previousDeleteFlag) {
        Remove-Item Env:\AI_OBSERVABILITY_DELETE_ENTRA_APP -ErrorAction SilentlyContinue
    }
    else {
        $env:AI_OBSERVABILITY_DELETE_ENTRA_APP = $previousDeleteFlag
    }
}

Write-Host 'Complete cleanup finished.'
exit 0