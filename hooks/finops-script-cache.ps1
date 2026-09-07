function Clear-FinOpsTriggerScriptCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][guid] $SubscriptionId,
        [Parameter(Mandatory = $true)][string] $ResourceGroupName,
        [Parameter(Mandatory = $true)][string] $HubName
    )

    $resourceGroupId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName"
    $hubId = "$resourceGroupId/providers/Microsoft.Cloud/hubs/$HubName"
    $scriptPrefix = "$resourceGroupId/providers/Microsoft.Resources/deploymentScripts/"
    $sourcePath = Join-Path $PSScriptRoot '..\infra\vendor\finops-toolkit\v14\release\modules\fx\scripts\Init-DataFactory.ps1'
    $expectedContent = Get-Content -LiteralPath $sourcePath -Raw
    $output = & az deployment-scripts list --subscription $SubscriptionId `
        --resource-group $ResourceGroupName --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Could not read the FinOps trigger script cache: $($output -join "`n")"
    }
    $resources = $output -join "`n" | ConvertFrom-Json -AsHashtable -NoEnumerate
    if ($resources -isnot [array]) {
        throw 'The FinOps deployment-script list must be a JSON array.'
    }

    $cachedScripts = @(
        foreach ($resource in $resources) {
            $tags = $resource['tags']
            if ($null -eq $tags -or $tags['cm-resource-parent'] -ine $hubId) {
                continue
            }
            if ($resource['scriptContent'] -cne $expectedContent) {
                continue
            }
            if ($resource['id'] -ine "$scriptPrefix$($resource['name'])" -or
                $resource['type'] -ine 'Microsoft.Resources/deploymentScripts') {
                throw 'A FinOps trigger script resolved outside the expected resource scope.'
            }
            if ($resource['provisioningState'] -ne 'Succeeded') {
                throw "Inspect FinOps trigger script $($resource['name']) before retrying. Its state is $($resource['provisioningState']); its logs were retained."
            }
            $resource
        }
    )

    # Unchanged v14 scripts stay cached for one hour, including between the two deployment passes.
    foreach ($resource in $cachedScripts) {
        Write-Host "Clearing completed FinOps trigger script record: $($resource['name'])"
        $output = & az deployment-scripts delete --subscription $SubscriptionId `
            --resource-group $ResourceGroupName --name $resource['name'] `
            --yes --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Could not clear FinOps trigger script $($resource['name']): $($output -join "`n")"
        }
    }
}
