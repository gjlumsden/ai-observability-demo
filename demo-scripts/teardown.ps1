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
$clientId = Get-AzdValue $azdValues 'ENTRA_CLIENT_ID'

Write-Host "This will permanently delete the azd environment resources with:"
Write-Host "  azd down --force --purge"
if ($clientId) {
    Write-Host "The postdown hook will also delete Entra app registration: $clientId"
}
Write-Host 'The postdown hook will delete the sibling FinOps resource group and external role assignments.'
Write-Host 'The purge-protected Key Vault will remain recoverable until its scheduled purge date.'

$confirmation = Read-Host "Type 'delete ai observability demo' to continue"
if ($confirmation -ne 'delete ai observability demo') {
    Write-Host "Teardown cancelled."
    exit 0
}

azd down --force --purge
$downExitCode = $LASTEXITCODE
if ($downExitCode -ne 0) {
    Write-Error "azd down failed with exit code $downExitCode."
    exit $downExitCode
}

Write-Host 'Complete cleanup finished.'
exit 0
