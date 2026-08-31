[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$policyPaths = @(
    'apim-policies\openai-model.xml'
    'apim-policies\claude-model.xml'
    'apim-policies\weather-agent-model.xml'
)
$expectedDimensions = @(
    'API ID'
    'Subscription ID'
    'Team'
    'Model'
    'Attribution Mode'
)
$forbiddenDimensions = @(
    'User'
    'Operation ID'
    'Product ID'
    'Project'
)
$expectedEventFields = @(
    'schemaVersion'
    'eventTimeUtc'
    'eventId'
    'correlationId'
    'traceId'
    'provider'
    'requestModel'
    'responseModel'
    'deploymentName'
    'deploymentType'
    'modelResourceId'
    'resourceGroupId'
    'teamId'
    'subjectId'
    'projectId'
    'attributionMode'
    'requestOutcome'
    'httpStatusCode'
    'latencyMs'
    'tokenQuality'
    'inputTokens'
    'cachedInputTokens'
    'uncachedInputTokens'
    'cacheWrite5mTokens'
    'cacheWrite1hTokens'
    'outputTokens'
    'reasoningTokens'
    'visibleOutputTokens'
    'totalTokens'
    'rawUsage'
)
$allowedRawUsageFields = @(
    'input_tokens'
    'output_tokens'
    'total_tokens'
    'prompt_tokens'
    'completion_tokens'
    'cache_read_input_tokens'
    'cache_creation_input_tokens'
    'thinking_tokens'
    'input_tokens_details'
    'prompt_tokens_details'
    'output_tokens_details'
    'completion_tokens_details'
    'cache_creation'
)

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool] $Condition,
        [Parameter(Mandatory = $true)][string] $Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-ExactSet {
    param(
        [Parameter(Mandatory = $true)][string[]] $Actual,
        [Parameter(Mandatory = $true)][string[]] $Expected,
        [Parameter(Mandatory = $true)][string] $Description
    )

    $actualSet = @($Actual | Sort-Object -Unique)
    $expectedSet = @($Expected | Sort-Object -Unique)
    $difference = @(Compare-Object -ReferenceObject $expectedSet -DifferenceObject $actualSet)
    Assert-True ($difference.Count -eq 0) "$Description differs from the expected set."
}

foreach ($relativePath in $policyPaths) {
    $path = Join-Path $repositoryRoot $relativePath
    Assert-True (Test-Path -LiteralPath $path -PathType Leaf) "The APIM policy is missing: $relativePath"

    [xml] $policy = Get-Content -LiteralPath $path -Raw
    Assert-True ($null -ne $policy.policies) "The APIM policy root is invalid: $relativePath"

    $metrics = @($policy.SelectNodes('//llm-emit-token-metric'))
    Assert-True ($metrics.Count -eq 1) "Expected one model metric policy in $relativePath."
    $dimensions = @($metrics[0].SelectNodes('./dimension'))
    $dimensionNames = @($dimensions | ForEach-Object { $_.GetAttribute('name') })
    Assert-True ($dimensions.Count -eq 5) "Expected exactly five model metric dimensions in $relativePath."
    Assert-ExactSet $dimensionNames $expectedDimensions "The metric dimensions in $relativePath"
    foreach ($forbidden in $forbiddenDimensions) {
        Assert-True ($dimensionNames -notcontains $forbidden) "The forbidden '$forbidden' dimension exists in $relativePath."
    }

    $subjectVariable = $policy.SelectSingleNode("//set-variable[@name='subject-id']")
    Assert-True ($null -ne $subjectVariable) "The subject pseudonym is missing in $relativePath."
    $subjectExpression = $subjectVariable.GetAttribute('value')
    Assert-True ($subjectExpression.Contains('HMACSHA256')) "The subject pseudonym does not use HMAC-SHA256 in $relativePath."
    Assert-True ($subjectExpression.Contains('{{usage-hmac-key}}')) "The HMAC key reference is missing in $relativePath."
    Assert-True ($subjectExpression.Contains("TrimEnd('=').Replace('+', '-').Replace('/', '_')")) "The subject pseudonym is not base64url encoded in $relativePath."

    $logs = @($policy.SelectNodes('//log-to-eventhub'))
    Assert-True ($logs.Count -ge 2) "Expected outbound and error Event Hubs logging in $relativePath."
    foreach ($log in $logs) {
        Assert-True ($log.GetAttribute('logger-id') -eq 'usage-event-hub') "An unexpected Event Hubs logger is used in $relativePath."
        $eventFields = @(
            [regex]::Matches($log.InnerText, 'usageEvent\["([^"]+)"\]') |
                ForEach-Object { $_.Groups[1].Value }
        )
        Assert-ExactSet $eventFields $expectedEventFields "The emitted usage event fields in $relativePath"

        $rawUsageFields = @(
            [regex]::Matches($log.InnerText, 'rawUsage\["([^"]+)"\]') |
                ForEach-Object { $_.Groups[1].Value }
        )
        foreach ($field in $rawUsageFields) {
            Assert-True ($allowedRawUsageFields -contains $field) "The forbidden raw usage field '$field' is emitted in $relativePath."
        }
    }

    $outboundLogs = @($policy.SelectNodes('/policies/outbound/log-to-eventhub'))
    Assert-True ($outboundLogs.Count -eq 1) "Expected one outbound Event Hubs log in $relativePath."
    Assert-True (
        $outboundLogs[0].InnerText.Contains(
            'context.Response.Body.As<string>(preserveContent: true)'
        )
    ) "The outbound policy does not preserve response content in $relativePath."
}

$key = [byte[]](1..32)
$material = 'tenant|entra-user|subject'
$hmac = [System.Security.Cryptography.HMACSHA256]::new()
$hmac.Key = $key
try {
    $firstDigest = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($material))
    $secondDigest = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($material))
}
finally {
    $hmac.Dispose()
}
$first = [Convert]::ToBase64String($firstDigest).TrimEnd('=').Replace('+', '-').Replace('/', '_')
$second = [Convert]::ToBase64String($secondDigest).TrimEnd('=').Replace('+', '-').Replace('/', '_')
Assert-True ($first -ceq $second) 'The HMAC pseudonym is not stable.'
Assert-True ($first.Length -eq 43) 'The HMAC pseudonym does not have the expected SHA-256 base64url length.'

Write-Host "Validated $($policyPaths.Count) APIM usage policies."
