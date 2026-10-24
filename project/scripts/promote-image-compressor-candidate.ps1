[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$CandidateRoot,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$PayloadBackupManifest,

    [ValidateSet('PASS', 'NOT_RUN')]
    [string]$OwnerReportedNativeMachineCheck = 'NOT_RUN'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_secret-path-guard.ps1')

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)

    return [IO.Path]::GetFullPath($Path).TrimEnd(
        [IO.Path]::DirectorySeparatorChar,
        [IO.Path]::AltDirectorySeparatorChar)
}

function Assert-PathWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    if (Test-SecretFilePath -FilePath $Path) { throw 'SECRET_PATH_REJECTED' }
    Assert-SafeFilePath -Path $Path
    Assert-SafeFilePath -Path $Root
    $rootFull = Get-NormalizedPath -Path $Root
    $pathFull = [IO.Path]::GetFullPath($Path)
    if ($pathFull -ne $rootFull -and
        -not $pathFull.StartsWith(
            $rootFull + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing path outside allowed root: $pathFull"
    }
    return $pathFull
}

function Assert-NotReparsePoint {
    param([Parameter(Mandatory)][string]$Path)

    Assert-SafeFilePath -Path $Path
    if ((Get-Item -LiteralPath $Path -Force).Attributes -band
        [IO.FileAttributes]::ReparsePoint) {
        throw "Reparse points are not allowed: $Path"
    }
}

function Get-FileRecord {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $item = Get-Item -LiteralPath $Path -Force
    return [ordered]@{
        name = $Name.Replace('\', '/')
        bytes = $item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
    }
}

function Test-FileRecord {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Record
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Expected file is missing: $Path"
    }
    Assert-NotReparsePoint -Path $Path
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Length -ne [long]$Record.bytes) {
        throw "File length mismatch: $Path"
    }
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($hash -ne [string]$Record.sha256) {
        throw "File hash mismatch: $Path"
    }
}

$projectRoot = Get-NormalizedPath -Path (Join-Path $PSScriptRoot '..')
$workspaceRoot = Get-NormalizedPath -Path (Join-Path $projectRoot '..\..')
$candidateRootAllowed = Join-Path $projectRoot '_internal\candidates'
$rollbackRoot = Join-Path $projectRoot '_internal\rollback'
$promotionRoot = Join-Path $projectRoot '_internal\promotions'
$currentPayloadRoot = Join-Path $projectRoot 'installer\payload'
$distributionTarget = Join-Path $projectRoot 'dist'

Assert-SafeFilePath -Path $projectRoot
$candidate = Assert-PathWithinRoot -Path $CandidateRoot -Root $candidateRootAllowed
$backupManifestPath = Assert-PathWithinRoot `
    -Path $PayloadBackupManifest `
    -Root $rollbackRoot
Assert-SafeFileTree -Path $candidate
Assert-SafeFileTree -Path $currentPayloadRoot
Assert-SafeFileTree -Path $distributionTarget
foreach ($requiredDirectory in $candidate, $currentPayloadRoot) {
    if (-not (Test-Path -LiteralPath $requiredDirectory -PathType Container)) {
        throw "Required directory is missing: $requiredDirectory"
    }
    Assert-NotReparsePoint -Path $requiredDirectory
}
if (-not (Test-Path -LiteralPath $backupManifestPath -PathType Leaf)) {
    throw "Payload backup manifest is missing: $backupManifestPath"
}
Assert-NotReparsePoint -Path $backupManifestPath
$distributionAlreadyPresent = Test-Path -LiteralPath $distributionTarget
$distributionMatchesCandidate = $false
if ($distributionAlreadyPresent) {
    if (-not (Test-Path -LiteralPath $distributionTarget -PathType Container)) {
        throw "Distribution target is not a directory: $distributionTarget"
    }
    Assert-NotReparsePoint -Path $distributionTarget
}

$candidateReceiptPath = Join-Path $candidate 'candidate-receipt.json'
$candidateReceipt = Get-Content -LiteralPath $candidateReceiptPath -Raw |
    ConvertFrom-Json
if ($candidateReceipt.schemaVersion -ne 1 -or
    $candidateReceipt.productId -ne 'image-compressor' -or
    [string]$candidateReceipt.productVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw 'Candidate receipt identity is invalid.'
}
foreach ($record in @($candidateReceipt.files)) {
    $candidateFile = Assert-PathWithinRoot `
        -Path (Join-Path $candidate ([string]$record.name)) `
        -Root $candidate
    Test-FileRecord -Path $candidateFile -Record $record
}
if ($distributionAlreadyPresent) {
    $expectedDistributionRecords = @($candidateReceipt.files | Where-Object {
            ([string]$_.name).StartsWith('dist/', [StringComparison]::Ordinal)
        })
    $actualDistributionFiles = @(Get-ChildItem `
            -LiteralPath $distributionTarget `
            -File `
            -Recurse)
    if ($actualDistributionFiles.Count -eq $expectedDistributionRecords.Count) {
        $distributionMatchesCandidate = $true
        foreach ($record in $expectedDistributionRecords) {
            $relative = ([string]$record.name).Substring(5).Replace('/', '\')
            try {
                Test-FileRecord `
                    -Path (Join-Path $distributionTarget $relative) `
                    -Record $record
            }
            catch {
                $distributionMatchesCandidate = $false
                break
            }
        }
    }
}

$candidatePayloadRoot = Join-Path $candidate 'payload'
$candidateDistRoot = Join-Path $candidate 'dist'
foreach ($requiredDirectory in $candidatePayloadRoot, $candidateDistRoot) {
    if (-not (Test-Path -LiteralPath $requiredDirectory -PathType Container)) {
        throw "Candidate directory is missing: $requiredDirectory"
    }
    Assert-NotReparsePoint -Path $requiredDirectory
}
$expectedPayloadNames = @(
    'ImageCompressor-win-arm64.zip',
    'ImageCompressor-win-x64.zip',
    'payload-manifest.json'
)
$actualPayloadNames = @(Get-ChildItem -LiteralPath $candidatePayloadRoot -File -Force |
    Select-Object -ExpandProperty Name |
    Sort-Object)
if (Compare-Object `
        -ReferenceObject ($expectedPayloadNames | Sort-Object) `
        -DifferenceObject $actualPayloadNames) {
    throw 'Candidate payload inventory is invalid.'
}

$backupManifest = Get-Content -LiteralPath $backupManifestPath -Raw |
    ConvertFrom-Json
if ($backupManifest.schemaVersion -ne 1 -or
    $backupManifest.productId -ne 'image-compressor') {
    throw 'Backup manifest identity is invalid.'
}
$backupRoot = Split-Path -Parent $backupManifestPath
Assert-NotReparsePoint -Path $backupRoot
$backupByName = @{}
foreach ($record in @($backupManifest.files)) {
    $name = Split-Path -Leaf ([string]$record.path)
    if ($name -notin $expectedPayloadNames -or $backupByName.ContainsKey($name)) {
        throw "Backup inventory is invalid: $name"
    }
    $backupFile = Assert-PathWithinRoot `
        -Path (Join-Path $backupRoot ([string]$record.path)) `
        -Root $backupRoot
    $currentFile = Assert-PathWithinRoot `
        -Path (Join-Path $currentPayloadRoot $name) `
        -Root $currentPayloadRoot
    Test-FileRecord -Path $backupFile -Record $record
    Test-FileRecord -Path $currentFile -Record $record
    $backupByName[$name] = [pscustomobject]@{
        Record = $record
        Path = $backupFile
    }
}
if ($backupByName.Count -ne $expectedPayloadNames.Count) {
    throw 'Backup payload inventory is incomplete.'
}

$candidatePayloadManifest = Get-Content `
    -LiteralPath (Join-Path $candidatePayloadRoot 'payload-manifest.json') `
    -Raw |
    ConvertFrom-Json
if ([string]$candidatePayloadManifest.productVersion -ne
    [string]$candidateReceipt.productVersion -or
    [string]$candidatePayloadManifest.buildId -ne
    [string]$candidateReceipt.buildId -or
    [string]$candidatePayloadManifest.sourceDigest -ne
    [string]$candidateReceipt.sourceDigest) {
    throw 'Candidate payload and receipt identity differ.'
}

Write-Host "Candidate: $candidate" -ForegroundColor Cyan
Write-Host "Build ID: $($candidateReceipt.buildId)" -ForegroundColor Cyan
Write-Host "Payload target: $currentPayloadRoot" -ForegroundColor Cyan
Write-Host "Distribution target: $distributionTarget" -ForegroundColor Cyan
Write-Host "Rollback manifest: $backupManifestPath" -ForegroundColor Cyan

if (-not $PSCmdlet.ShouldProcess(
        "$currentPayloadRoot and $distributionTarget",
        "Promote Image Compressor $($candidateReceipt.productVersion)")) {
    Write-Host 'Promotion dry-run completed. No files were modified.' -ForegroundColor Yellow
    return
}

$promotionId = Get-Date -Format 'yyyyMMddTHHmmsszzz'
$promotionId = $promotionId.Replace(':', '')
$candidateName = Split-Path -Leaf $candidate
$promotionDirectory = Assert-PathWithinRoot `
    -Path (Join-Path $promotionRoot "$promotionId-$candidateName") `
    -Root $promotionRoot
if (Test-Path -LiteralPath $promotionDirectory) {
    throw "Promotion receipt directory already exists: $promotionDirectory"
}
New-Item -ItemType Directory -Path $promotionDirectory | Out-Null
Assert-NotReparsePoint -Path $promotionDirectory

$token = [guid]::NewGuid().ToString('N')
$distStaging = Assert-PathWithinRoot `
    -Path (Join-Path $projectRoot ".image-compressor-dist-promotion-$token") `
    -Root $projectRoot
$payloadStaging = @{}
$distributionMoved = $false
$distributionBackup = Join-Path $promotionDirectory 'pre-promotion-dist'
$payloadMutationStarted = $false

try {
    if (-not $distributionMatchesCandidate) {
        Copy-Item -LiteralPath $candidateDistRoot -Destination $distStaging -Recurse
        Assert-NotReparsePoint -Path $distStaging
        foreach ($record in @($candidateReceipt.files | Where-Object {
                    ([string]$_.name).StartsWith('dist/', [StringComparison]::Ordinal)
                })) {
            $relative = ([string]$record.name).Substring(5).Replace('/', '\')
            Test-FileRecord `
                -Path (Join-Path $distStaging $relative) `
                -Record $record
        }
    }

    foreach ($name in $expectedPayloadNames) {
        $source = Join-Path $candidatePayloadRoot $name
        $staged = Assert-PathWithinRoot `
            -Path (Join-Path $currentPayloadRoot ".$token-$name") `
            -Root $currentPayloadRoot
        Copy-Item -LiteralPath $source -Destination $staged
        $sourceRecord = Get-FileRecord -Path $source -Name $name
        Test-FileRecord -Path $staged -Record ([pscustomobject]$sourceRecord)
        $payloadStaging[$name] = $staged
    }

    if (-not $distributionMatchesCandidate) {
        if ($distributionAlreadyPresent) {
            [IO.Directory]::Move($distributionTarget, $distributionBackup)
        }
        [IO.Directory]::Move($distStaging, $distributionTarget)
        $distributionMoved = $true
    }

    foreach ($name in $expectedPayloadNames) {
        $payloadMutationStarted = $true
        $replaceBackup = Assert-PathWithinRoot `
            -Path (Join-Path $promotionDirectory "pre-promotion-$name") `
            -Root $promotionDirectory
        [IO.File]::Replace(
            [string]$payloadStaging[$name],
            (Join-Path $currentPayloadRoot $name),
            $replaceBackup)
    }

    foreach ($name in $expectedPayloadNames) {
        $candidateRecord = Get-FileRecord `
            -Path (Join-Path $candidatePayloadRoot $name) `
            -Name $name
        Test-FileRecord `
            -Path (Join-Path $currentPayloadRoot $name) `
            -Record ([pscustomobject]$candidateRecord)
    }
    foreach ($record in @($candidateReceipt.files | Where-Object {
                ([string]$_.name).StartsWith('dist/', [StringComparison]::Ordinal)
            })) {
        $relative = ([string]$record.name).Substring(5).Replace('/', '\')
        Test-FileRecord `
            -Path (Join-Path $distributionTarget $relative) `
            -Record $record
    }
}
catch {
    $promotionFailure = $_
    if ($payloadMutationStarted) {
        foreach ($name in $expectedPayloadNames) {
            $restoreStaging = Assert-PathWithinRoot `
                -Path (Join-Path $currentPayloadRoot ".$token-restore-$name") `
                -Root $currentPayloadRoot
            Copy-Item -LiteralPath $backupByName[$name].Path -Destination $restoreStaging
            Test-FileRecord `
                -Path $restoreStaging `
                -Record $backupByName[$name].Record
            $failedTarget = Assert-PathWithinRoot `
                -Path (Join-Path $promotionDirectory "failed-target-$name") `
                -Root $promotionDirectory
            [IO.File]::Replace(
                $restoreStaging,
                (Join-Path $currentPayloadRoot $name),
                $failedTarget)
        }
    }
    if ($distributionMoved -and (Test-Path -LiteralPath $distributionTarget)) {
        $failedDistribution = Assert-PathWithinRoot `
            -Path (Join-Path $promotionDirectory 'failed-dist') `
            -Root $promotionDirectory
        [IO.Directory]::Move($distributionTarget, $failedDistribution)
    }
    if (Test-Path -LiteralPath $distributionBackup -PathType Container) {
        [IO.Directory]::Move($distributionBackup, $distributionTarget)
    }
    throw "Promotion failed and rollback was attempted: $($promotionFailure.Exception.Message)"
}

$recoveredStagingRoot = Join-Path $promotionDirectory 'recovered-staging'
$staleStagingFiles = @(Get-ChildItem -LiteralPath $currentPayloadRoot -File -Force |
    Where-Object {
        $_.Name -match '^\.[0-9a-f]{32}-(restore-)?(ImageCompressor-win-arm64\.zip|ImageCompressor-win-x64\.zip|payload-manifest\.json)$'
    })
if ($staleStagingFiles.Count -gt 0) {
    New-Item -ItemType Directory -Path $recoveredStagingRoot | Out-Null
    Assert-NotReparsePoint -Path $recoveredStagingRoot
    foreach ($staleFile in $staleStagingFiles) {
        Assert-NotReparsePoint -Path $staleFile.FullName
        Move-Item -LiteralPath $staleFile.FullName -Destination $recoveredStagingRoot
    }
}

$promotionReceiptPath = Join-Path $promotionDirectory 'promotion-receipt.json'
$promotedFiles = @(
    foreach ($name in $expectedPayloadNames) {
        Get-FileRecord `
            -Path (Join-Path $currentPayloadRoot $name) `
            -Name "installer/payload/$name"
    }
    foreach ($file in Get-ChildItem -LiteralPath $distributionTarget -File -Recurse |
        Sort-Object FullName) {
        Get-FileRecord `
            -Path $file.FullName `
            -Name ("dist/" + [IO.Path]::GetRelativePath(
                    $distributionTarget,
                    $file.FullName))
    }
)
$receipt = [ordered]@{
    schemaVersion = 1
    productId = 'image-compressor'
    productVersion = [string]$candidateReceipt.productVersion
    buildId = [string]$candidateReceipt.buildId
    sourceDigest = [string]$candidateReceipt.sourceDigest
    promotedAt = [DateTimeOffset]::Now.ToString('o')
    candidateRoot = [IO.Path]::GetRelativePath(
        $workspaceRoot,
        $candidate).Replace('\', '/')
    payloadBackupManifest = [IO.Path]::GetRelativePath(
        $workspaceRoot,
        $backupManifestPath).Replace('\', '/')
    targets = @(
        [IO.Path]::GetRelativePath($workspaceRoot, $currentPayloadRoot).Replace('\', '/'),
        [IO.Path]::GetRelativePath($workspaceRoot, $distributionTarget).Replace('\', '/')
    )
    ownerReportedNativeMachineCheck = $OwnerReportedNativeMachineCheck
    files = $promotedFiles
}
$receipt | ConvertTo-Json -Depth 20 |
    Set-Content -LiteralPath $promotionReceiptPath -Encoding utf8

Write-Host "Promotion completed: $promotionReceiptPath" -ForegroundColor Green
