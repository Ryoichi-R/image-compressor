[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputRoot,

    [string]$PayloadBackupManifest,

    [switch]$AllowUnpublishedSameVersionRebuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$candidateBuilder = Join-Path $PSScriptRoot 'new-image-compressor-candidate-package.ps1'
if (-not (Test-Path -LiteralPath $candidateBuilder -PathType Leaf)) {
    throw "Candidate builder is missing: $candidateBuilder"
}
& $candidateBuilder @PSBoundParameters
if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}
return

<#
Legacy destructive implementation retained temporarily for audit history.
It is intentionally unreachable: the wrapper above delegates only to the
candidate builder, which never writes installer/payload or project/dist.

function Assert-PathWithinRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $pathFull = [IO.Path]::GetFullPath($Path)
    if ($pathFull -ne $rootFull -and
        -not $pathFull.StartsWith(
            $rootFull + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to write outside workspace root: $pathFull"
    }
    return $pathFull
}

function Clear-GeneratedDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ExpectedLeaf
    )

    $safe = Assert-PathWithinRoot -Path $Path -Root $Root
    if ((Split-Path -Leaf $safe) -cne $ExpectedLeaf) {
        throw "Refusing to clear unexpected generated directory: $safe"
    }
    New-Item -ItemType Directory -Path $safe -Force | Out-Null
    foreach ($child in Get-ChildItem -LiteralPath $safe -Force) {
        $safeChild = Assert-PathWithinRoot -Path $child.FullName -Root $safe
        Remove-Item -LiteralPath $safeChild -Recurse -Force
    }
}

function Get-PeMachine {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        $stream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "Invalid PE signature: $Path"
        }
        return $reader.ReadUInt16()
    }
    finally {
        $stream.Dispose()
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    $json = $Value | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    $null = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$facadeRoot = [IO.Path]::GetFullPath((Split-Path -Parent $projectRoot))
$workspaceRoot = [IO.Path]::GetFullPath((Split-Path -Parent $facadeRoot))
$null = Assert-PathWithinRoot -Path $projectRoot -Root $workspaceRoot
$project = Assert-PathWithinRoot `
    -Path (Join-Path $projectRoot 'src\ImageCompressor.App\ImageCompressor.App.csproj') `
    -Root $projectRoot
$installerRoot = Assert-PathWithinRoot `
    -Path (Join-Path $projectRoot 'installer') `
    -Root $projectRoot
$payloadRoot = Assert-PathWithinRoot `
    -Path (Join-Path $installerRoot 'payload') `
    -Root $installerRoot
$distributionRoot = Assert-PathWithinRoot `
    -Path (Join-Path $projectRoot 'dist\image-compressor-installer') `
    -Root $projectRoot
$distributionArchive = Assert-PathWithinRoot `
    -Path (Join-Path $projectRoot 'dist\image-compressor-installer.zip') `
    -Root $projectRoot
$distributionManifest = Assert-PathWithinRoot `
    -Path (Join-Path $projectRoot 'dist\image-compressor-installer.manifest.json') `
    -Root $projectRoot
$entryBatch = Assert-PathWithinRoot `
    -Path (Join-Path $facadeRoot 'ここから開始 - Image Compressorを導入・更新.bat') `
    -Root $facadeRoot
$installerScript = Assert-PathWithinRoot `
    -Path (Join-Path $installerRoot 'Install-ImageCompressor.ps1') `
    -Root $installerRoot
$packageReadme = Assert-PathWithinRoot `
    -Path (Join-Path $installerRoot 'README.md') `
    -Root $installerRoot
$appReadme = Assert-PathWithinRoot `
    -Path (Join-Path $projectRoot 'README.md') `
    -Root $projectRoot
$settings = Assert-PathWithinRoot `
    -Path (Join-Path $installerRoot 'assets\settings.json') `
    -Root $installerRoot
$settingsExample = Assert-PathWithinRoot `
    -Path (Join-Path $installerRoot 'assets\settings.example.json') `
    -Root $installerRoot

foreach ($required in @(
        $project,
        $entryBatch,
        $installerScript,
        $packageReadme,
        $appReadme,
        $settings,
        $settingsExample
    )) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required installer source is missing: $required"
    }
}

[xml]$buildProps = Get-Content -LiteralPath (Join-Path $projectRoot 'Directory.Build.props') -Raw
$productVersion = [string]$buildProps.Project.PropertyGroup.Version
if ([string]::IsNullOrWhiteSpace($productVersion)) {
    throw 'Product version is missing from Directory.Build.props.'
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) (
    'ImageCompressorInstallerBuild-{0}' -f [guid]::NewGuid().ToString('N'))
$temporaryRoot = [IO.Path]::GetFullPath($temporaryRoot)
$payloads = [ordered]@{}

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    Clear-GeneratedDirectory -Path $payloadRoot -Root $installerRoot -ExpectedLeaf 'payload'

    foreach ($definition in @(
            [pscustomobject]@{ Runtime = 'win-x64'; Machine = 0x8664 },
            [pscustomobject]@{ Runtime = 'win-arm64'; Machine = 0xAA64 }
        )) {
        $runtime = $definition.Runtime
        $publishDirectory = Join-Path $temporaryRoot "publish-$runtime"
        $buildArtifacts = Join-Path $temporaryRoot "artifacts-$runtime"
        Write-Host "==> Publish prebuilt $runtime payload" -ForegroundColor Cyan
        & dotnet publish $project `
            --configuration Release `
            --runtime $runtime `
            --self-contained true `
            --output $publishDirectory `
            --artifacts-path $buildArtifacts `
            --nologo `
            -p:PublishSingleFile=true `
            -p:IncludeNativeLibrariesForSelfExtract=true `
            -p:DebugType=None `
            -p:DebugSymbols=false
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet publish $runtime failed with exit code $LASTEXITCODE"
        }

        Copy-Item -LiteralPath $appReadme -Destination (Join-Path $publishDirectory 'README.md') -Force
        Copy-Item -LiteralPath $settings -Destination (Join-Path $publishDirectory 'settings.json') -Force
        Copy-Item -LiteralPath $settingsExample -Destination (Join-Path $publishDirectory 'settings.example.json') -Force

        $expectedNames = @(
            'ImageCompressor.App.exe',
            'README.md',
            'settings.example.json',
            'settings.json'
        )
        $actualNames = @(Get-ChildItem -LiteralPath $publishDirectory -File |
            Select-Object -ExpandProperty Name |
            Sort-Object)
        if (Compare-Object -ReferenceObject ($expectedNames | Sort-Object) -DifferenceObject $actualNames) {
            throw "Unexpected files were produced for $runtime`: $($actualNames -join ', ')"
        }

        $executable = Join-Path $publishDirectory 'ImageCompressor.App.exe'
        $machine = Get-PeMachine -Path $executable
        if ($machine -ne $definition.Machine) {
            throw ('PE architecture mismatch for {0}. Expected 0x{1:X4}, actual 0x{2:X4}.' -f
                $runtime, $definition.Machine, $machine)
        }

        $managedFiles = @(
            foreach ($name in @('ImageCompressor.App.exe', 'README.md', 'settings.example.json')) {
                $file = Join-Path $publishDirectory $name
                [ordered]@{
                    name = $name
                    bytes = (Get-Item -LiteralPath $file).Length
                    sha256 = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
                }
            }
        )
        $archiveName = "ImageCompressor-$runtime.zip"
        $archivePath = Join-Path $payloadRoot $archiveName
        Compress-Archive `
            -Path (Join-Path $publishDirectory '*') `
            -DestinationPath $archivePath `
            -CompressionLevel Optimal
        $payloads[$runtime] = [ordered]@{
            archive = $archiveName
            bytes = (Get-Item -LiteralPath $archivePath).Length
            sha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
            peMachine = $definition.Machine
            executableSha256 = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
            managedFiles = $managedFiles
            userOwnedFiles = @('settings.json')
        }
    }

    $payloadManifestPath = Join-Path $payloadRoot 'payload-manifest.json'
    Write-JsonFile -Path $payloadManifestPath -Value ([ordered]@{
            schemaVersion = 1
            productId = 'image-compressor'
            productName = 'Image Compressor'
            productVersion = $productVersion
            createdAt = [DateTimeOffset]::Now.ToString('o')
            payloads = $payloads
        })

    Clear-GeneratedDirectory `
        -Path $distributionRoot `
        -Root (Join-Path $projectRoot 'dist') `
        -ExpectedLeaf 'image-compressor-installer'
    Copy-Item -LiteralPath $entryBatch -Destination $distributionRoot
    Copy-Item -LiteralPath $packageReadme -Destination (Join-Path $distributionRoot 'README.md')
    $distributionInstaller = Join-Path $distributionRoot 'installer'
    $distributionPayload = Join-Path $distributionInstaller 'payload'
    New-Item -ItemType Directory -Path $distributionPayload -Force | Out-Null
    Copy-Item -LiteralPath $installerScript -Destination $distributionInstaller
    foreach ($payloadFile in Get-ChildItem -LiteralPath $payloadRoot -File) {
        Copy-Item -LiteralPath $payloadFile.FullName -Destination $distributionPayload
    }

    if (Test-Path -LiteralPath $distributionArchive) {
        Remove-Item -LiteralPath $distributionArchive -Force
    }
    Compress-Archive `
        -Path (Join-Path $distributionRoot '*') `
        -DestinationPath $distributionArchive `
        -CompressionLevel Optimal

    $distributionFiles = @(
        Get-ChildItem -LiteralPath $distributionRoot -File -Recurse |
            Sort-Object FullName |
            ForEach-Object {
                [ordered]@{
                    path = [IO.Path]::GetRelativePath($distributionRoot, $_.FullName).Replace('\', '/')
                    bytes = $_.Length
                    sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
                }
            }
    )
    Write-JsonFile -Path $distributionManifest -Value ([ordered]@{
            schemaVersion = 1
            productId = 'image-compressor'
            productVersion = $productVersion
            createdAt = [DateTimeOffset]::Now.ToString('o')
            archive = [IO.Path]::GetFileName($distributionArchive)
            archiveBytes = (Get-Item -LiteralPath $distributionArchive).Length
            archiveSha256 = (Get-FileHash -LiteralPath $distributionArchive -Algorithm SHA256).Hash
            files = $distributionFiles
        })

    Write-Host "Installer folder: $distributionRoot" -ForegroundColor Green
    Write-Host "Installer archive: $distributionArchive" -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
#>
