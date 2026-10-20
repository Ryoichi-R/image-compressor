[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedDirectoryPath {
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

    $rootFull = Get-NormalizedDirectoryPath -Path $Root
    $pathFull = [IO.Path]::GetFullPath($Path)
    if ($pathFull -ne $rootFull -and
        -not $pathFull.StartsWith(
            $rootFull + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to write outside the allowed root: $pathFull"
    }
    return $pathFull
}

function Assert-NotReparsePoint {
    param([Parameter(Mandatory)][string]$Path)

    if ((Get-Item -LiteralPath $Path -Force).Attributes -band
        [IO.FileAttributes]::ReparsePoint) {
        throw "Reparse points are not allowed: $Path"
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    $json = $Value | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText(
        $Path,
        $json + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))
    $null = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$workspaceRoot = [IO.Path]::GetFullPath(
    (Split-Path -Parent (Split-Path -Parent $projectRoot)))
$rollbackRoot = Assert-PathWithinRoot `
    -Path (Join-Path $projectRoot '_internal\rollback') `
    -Root $workspaceRoot
$payloadRoot = Assert-PathWithinRoot `
    -Path (Join-Path $projectRoot 'installer\payload') `
    -Root $projectRoot
$destination = Assert-PathWithinRoot -Path $DestinationRoot -Root $rollbackRoot

if ((Split-Path -Parent $destination) -ne $rollbackRoot) {
    throw 'Payload backups must be direct children of _internal\rollback.'
}
if (-not (Test-Path -LiteralPath $rollbackRoot -PathType Container)) {
    throw "Rollback root is missing: $rollbackRoot"
}
if (-not (Test-Path -LiteralPath $payloadRoot -PathType Container)) {
    throw "Payload root is missing: $payloadRoot"
}
Assert-NotReparsePoint -Path $rollbackRoot
Assert-NotReparsePoint -Path $payloadRoot
if (Test-Path -LiteralPath $destination) {
    throw "Backup destination already exists: $destination"
}

$sourceFiles = @(Get-ChildItem -LiteralPath $payloadRoot -File -Force | Sort-Object Name)
if ($sourceFiles.Count -eq 0) {
    throw "Payload root is empty: $payloadRoot"
}
foreach ($sourceFile in $sourceFiles) {
    Assert-NotReparsePoint -Path $sourceFile.FullName
}

$sourceManifestPath = Join-Path $payloadRoot 'payload-manifest.json'
if (-not (Test-Path -LiteralPath $sourceManifestPath -PathType Leaf)) {
    throw 'payload-manifest.json is missing from the source payload.'
}
$sourceManifest = Get-Content -LiteralPath $sourceManifestPath -Raw | ConvertFrom-Json

New-Item -ItemType Directory -Path $destination | Out-Null
$backupPayloadRoot = Join-Path $destination 'payload'
New-Item -ItemType Directory -Path $backupPayloadRoot | Out-Null

$files = @(
    foreach ($sourceFile in $sourceFiles) {
        $destinationFile = Assert-PathWithinRoot `
            -Path (Join-Path $backupPayloadRoot $sourceFile.Name) `
            -Root $backupPayloadRoot
        Copy-Item -LiteralPath $sourceFile.FullName -Destination $destinationFile
        $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash
        $destinationHash = (Get-FileHash -LiteralPath $destinationFile -Algorithm SHA256).Hash
        if ($destinationHash -ne $sourceHash) {
            throw "Backup hash verification failed: $($sourceFile.Name)"
        }
        [ordered]@{
            path = "payload/$($sourceFile.Name)"
            bytes = $sourceFile.Length
            sha256 = $sourceHash
        }
    }
)

$backupManifestPath = Join-Path $destination 'payload-backup-manifest.json'
Write-JsonFile -Path $backupManifestPath -Value ([ordered]@{
        schemaVersion = 1
        productId = 'image-compressor'
        productVersion = [string]$sourceManifest.productVersion
        createdAt = [DateTimeOffset]::Now.ToString('o')
        source = 'image-compressor/project/installer/payload'
        files = $files
    })

Write-Host "Payload backup: $destination" -ForegroundColor Green
Write-Host "Backup manifest: $backupManifestPath" -ForegroundColor Green
