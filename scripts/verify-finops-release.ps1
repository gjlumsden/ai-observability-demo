[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$vendorRoot = Join-Path $repositoryRoot 'infra\vendor\finops-toolkit\v14'
$manifestPath = Join-Path $vendorRoot 'RELEASE-MANIFEST.json'

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "The FinOps release manifest is missing: $manifestPath"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$expectedCommit = 'f3b1b23f3ea6044bcd8cb767620cdd43704ce90a'
$expectedDigest = 'cd8cae56daa324552efad711ff0f23cdb1b671e9eae215b95861029311dc8ca2'
$expectedReleaseUrl = 'https://github.com/microsoft/finops-toolkit/releases/download/v14/finops-hub-v14.zip'

if ($manifest.version -ne 'v14' -or $manifest.sourceCommit -ne $expectedCommit) {
    throw 'The FinOps release manifest does not identify the approved v14 commit.'
}

if ($manifest.sha256 -ne $expectedDigest) {
    throw 'The FinOps release manifest contains an unexpected SHA-256 digest.'
}
if ($manifest.releaseUrl -ne $expectedReleaseUrl) {
    throw 'The FinOps release manifest contains an unexpected release URL.'
}

$archivePath = Join-Path $vendorRoot $manifest.releaseAsset
if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "The vendored FinOps release archive is missing: $archivePath"
}

$actualDigest = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualDigest -ne $expectedDigest) {
    throw "FinOps release digest mismatch. Expected $expectedDigest, received $actualDigest."
}

$releaseRoot = Join-Path $vendorRoot $manifest.extractedDirectory
$requiredFiles = @(
    'main.bicep',
    'modules\hub.bicep',
    'modules\fx\ftkver.txt',
    'modules\Microsoft.CostManagement\ManagedExports\app.bicep',
    'modules\Microsoft.FinOpsHubs\Core\app.bicep'
)

foreach ($relativePath in $requiredFiles) {
    $path = Join-Path $releaseRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "The extracted FinOps release is incomplete. Missing: $relativePath"
    }
}

$version = (Get-Content -LiteralPath (Join-Path $releaseRoot 'modules\fx\ftkver.txt') -Raw).Trim()
if ($version -ne '14.0') {
    throw "The extracted FinOps release version is '$version', not '14.0'."
}

$archive = [System.IO.Compression.ZipFile]::OpenRead($archivePath)
try {
    $archiveFiles = @($archive.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) })
    $extractedFiles = @(Get-ChildItem -LiteralPath $releaseRoot -Recurse -File)
    if ($archiveFiles.Count -ne $extractedFiles.Count) {
        throw "The extracted FinOps release has $($extractedFiles.Count) files. The archive has $($archiveFiles.Count)."
    }

    foreach ($entry in $archiveFiles) {
        $candidate = [System.IO.Path]::GetFullPath((Join-Path $releaseRoot $entry.FullName))
        if (-not $candidate.StartsWith([System.IO.Path]::GetFullPath($releaseRoot), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "The FinOps archive contains an unsafe path: $($entry.FullName)"
        }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            throw "The extracted FinOps release is missing archive member: $($entry.FullName)"
        }

        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        $entryStream = $entry.Open()
        try {
            $entryDigest = [Convert]::ToHexString($sha256.ComputeHash($entryStream))
        }
        finally {
            $entryStream.Dispose()
            $sha256.Dispose()
        }

        $fileDigest = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash
        if ($fileDigest -ne $entryDigest) {
            throw "The extracted FinOps release differs from the verified archive: $($entry.FullName)"
        }
    }
}
finally {
    $archive.Dispose()
}

$untrackedVendorFiles = @(
    & git -C $repositoryRoot ls-files --others --exclude-standard -- 'infra/vendor/finops-toolkit/v14/release'
)
$trackedVendorFiles = @(
    & git -C $repositoryRoot ls-files -- 'infra/vendor/finops-toolkit/v14/release'
)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect the vendored FinOps release files.'
}
$repositoryVendorFiles = @($untrackedVendorFiles + $trackedVendorFiles | Sort-Object -Unique)
if ($repositoryVendorFiles.Count -ne $extractedFiles.Count) {
    throw "The repository contains $($repositoryVendorFiles.Count) release files. The verified archive contains $($extractedFiles.Count)."
}

Write-Host "Verified Microsoft FinOps toolkit v14 at commit $expectedCommit."
Write-Host "Verified SHA-256: $expectedDigest"
