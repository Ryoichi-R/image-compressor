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
. (Join-Path $PSScriptRoot '_secret-path-guard.ps1')

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

    if (Test-SecretFilePath -FilePath $Path) { throw 'SECRET_PATH_REJECTED' }
    Assert-SafeFilePath -Path $Path
    Assert-SafeFilePath -Path $Root
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

    Assert-SafeFilePath -Path $Path
    if ((Get-Item -LiteralPath $Path -Force).Attributes -band
        [IO.FileAttributes]::ReparsePoint) {
        throw "Reparse points are not allowed: $Path"
    }
}

function Get-PeMachine {
    param([Parameter(Mandatory)][string]$Path)

    Assert-SafeFilePath -Path $Path
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

function Test-FileContainsUtf8Text {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text
    )

    Assert-SafeFilePath -Path $Path
    $carry = ''
    $buffer = [byte[]]::new(4MB)
    $stream = [IO.File]::OpenRead($Path)
    try {
        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $chunk = $carry + [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
            if ($chunk.Contains($Text, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
            $carryLength = [Math]::Min([Math]::Max($Text.Length - 1, 0), $chunk.Length)
            $carry = if ($carryLength -gt 0) {
                $chunk.Substring($chunk.Length - $carryLength)
            }
            else {
                ''
            }
        }
    }
    finally {
        $stream.Dispose()
    }
    return $false
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path
    )

    Assert-SafeFilePath -Path $Path
    $json = $Value | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText(
        $Path,
        $json + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))
    $null = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-FileRecord {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    Assert-SafeFilePath -Path $Path
    $item = Get-Item -LiteralPath $Path
    return [ordered]@{
        name = $Name.Replace('\', '/')
        bytes = $item.Length
        sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
    }
}

function Get-CanonicalSourceDigest {
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [Parameter(Mandatory)][string]$FacadeRoot,
        [Parameter(Mandatory)][string]$WorkspaceRoot
    )

    $files = [Collections.Generic.List[string]]::new()
    foreach ($root in @(
            (Join-Path $ProjectRoot 'src'),
            (Join-Path $ProjectRoot 'installer\assets')
        )) {
        Assert-SafeFileTree -Path $root
        foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse) {
            if ($file.FullName -match '[\\/](bin|obj)[\\/]') {
                continue
            }
            $files.Add($file.FullName)
        }
    }

    foreach ($path in @(
            (Join-Path $ProjectRoot 'ImageCompressor.slnx'),
            (Join-Path $ProjectRoot 'Directory.Build.props'),
            (Join-Path $ProjectRoot 'Directory.Packages.props'),
            (Join-Path $ProjectRoot 'global.json'),
            (Join-Path $ProjectRoot 'NuGet.config'),
            (Join-Path $ProjectRoot 'README.md'),
            (Join-Path $ProjectRoot 'image-compressor.bat'),
            (Join-Path $ProjectRoot 'installer\Install-ImageCompressor.ps1'),
            (Join-Path $ProjectRoot 'installer\README.md'),
            (Join-Path $ProjectRoot 'scripts\_secret-path-guard.ps1'),
            (Join-Path $ProjectRoot 'scripts\backup-image-compressor-payload.ps1'),
            (Join-Path $ProjectRoot 'scripts\build-image-compressor-installer-package.ps1'),
            (Join-Path $ProjectRoot 'scripts\new-image-compressor-candidate-package.ps1'),
            (Join-Path $FacadeRoot 'README.md'),
            (Join-Path $FacadeRoot 'LICENSE'),
            (Join-Path $FacadeRoot 'ここから開始 - Image Compressorを導入・更新.bat')
        )) {
        $files.Add([IO.Path]::GetFullPath($path))
    }

    foreach ($lockFile in Get-ChildItem -LiteralPath $ProjectRoot -Filter 'packages.lock.json' -File -Recurse) {
        if ($lockFile.FullName -notmatch '[\\/](bin|obj|dist|payload|runs|rollback|candidates)[\\/]') {
            $files.Add($lockFile.FullName)
        }
    }

    $records = @(
        foreach ($file in $files | Sort-Object -Unique) {
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
                throw "Canonical build input is missing: $file"
            }
            Assert-SafeFilePath -Path $file
            $relative = [IO.Path]::GetRelativePath($WorkspaceRoot, $file).Replace('\', '/')
            $item = Get-Item -LiteralPath $file
            $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
            "$relative|$($item.Length)|$hash"
        }
    )
    $canonical = ($records -join "`n") + "`n"
    $bytes = [Text.Encoding]::UTF8.GetBytes($canonical)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
}

function Test-PayloadBackup {
    param(
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$RollbackRoot,
        [Parameter(Mandatory)][string]$CurrentPayloadRoot
    )

    $manifestFull = Assert-PathWithinRoot -Path $ManifestPath -Root $RollbackRoot
    if (-not (Test-Path -LiteralPath $manifestFull -PathType Leaf)) {
        throw "Payload backup manifest is missing: $manifestFull"
    }
    $manifest = Get-Content -LiteralPath $manifestFull -Raw | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.productId -ne 'image-compressor') {
        throw 'Payload backup manifest schema or product id is invalid.'
    }

    $backupRoot = Split-Path -Parent $manifestFull
    Assert-NotReparsePoint -Path $backupRoot
    $expectedNames = @($manifest.files | ForEach-Object {
            Split-Path -Leaf ([string]$_.path)
        } | Sort-Object)
    $currentNames = @(Get-ChildItem -LiteralPath $CurrentPayloadRoot -File -Force |
        Select-Object -ExpandProperty Name |
        Sort-Object)
    if (Compare-Object -ReferenceObject $expectedNames -DifferenceObject $currentNames) {
        throw 'Current payload inventory differs from the verified backup manifest.'
    }

    foreach ($entry in @($manifest.files)) {
        $relativePath = ([string]$entry.path).Replace('/', '\')
        $name = Split-Path -Leaf $relativePath
        if ([string]::IsNullOrWhiteSpace($name)) {
            throw "Invalid backup file name: $($entry.path)"
        }
        $backupFile = Assert-PathWithinRoot `
            -Path (Join-Path $backupRoot $relativePath) `
            -Root $backupRoot
        $currentFile = Assert-PathWithinRoot `
            -Path (Join-Path $CurrentPayloadRoot $name) `
            -Root $CurrentPayloadRoot
        foreach ($file in $backupFile, $currentFile) {
            if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
                throw "Payload verification file is missing: $file"
            }
            Assert-NotReparsePoint -Path $file
            if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -ne [string]$entry.sha256) {
                throw "Payload backup verification failed: $file"
            }
            if ((Get-Item -LiteralPath $file).Length -ne [long]$entry.bytes) {
                throw "Payload backup length verification failed: $file"
            }
        }
    }
    return [pscustomobject]@{
        ManifestPath = $manifestFull
        ProductVersion = [string]$manifest.productVersion
    }
}

function Test-SameVersionContent {
    param(
        [Parameter(Mandatory)]$ExistingManifest,
        [Parameter(Mandatory)]$CandidatePayloads
    )

    foreach ($runtime in 'win-x64', 'win-arm64') {
        $existing = $ExistingManifest.payloads.PSObject.Properties[$runtime].Value
        $candidate = $CandidatePayloads[$runtime]
        $existingRecords = @($existing.managedFiles | ForEach-Object {
                '{0}|{1}' -f $_.name, $_.sha256
            } | Sort-Object)
        $candidateRecords = @($candidate.managedFiles | ForEach-Object {
                '{0}|{1}' -f $_.name, $_.sha256
            } | Sort-Object)
        if (Compare-Object -ReferenceObject $existingRecords -DifferenceObject $candidateRecords) {
            return $false
        }
    }
    return $true
}

$projectRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$facadeRoot = [IO.Path]::GetFullPath((Split-Path -Parent $projectRoot))
$workspaceRoot = [IO.Path]::GetFullPath((Split-Path -Parent $facadeRoot))
Assert-SafeFilePath -Path $facadeRoot
$rollbackRoot = Assert-PathWithinRoot `
    -Path (Join-Path $projectRoot '_internal\rollback') `
    -Root $workspaceRoot
$currentPayloadRoot = Assert-PathWithinRoot `
    -Path (Join-Path $projectRoot 'installer\payload') `
    -Root $projectRoot
$output = Assert-PathWithinRoot -Path $OutputRoot -Root $workspaceRoot
$outputParent = Split-Path -Parent $output

if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    throw "Candidate output parent must already exist: $outputParent"
}
Assert-NotReparsePoint -Path $outputParent
if (Test-Path -LiteralPath $output) {
    throw "Candidate output root already exists: $output"
}

$backup = $null
$existingPayloadManifest = $null
if (-not [string]::IsNullOrWhiteSpace($PayloadBackupManifest)) {
    if (-not (Test-Path -LiteralPath $currentPayloadRoot -PathType Container)) {
        throw 'Current payload root is missing for the supplied backup manifest.'
    }
    $backup = Test-PayloadBackup `
        -ManifestPath $PayloadBackupManifest `
        -RollbackRoot $rollbackRoot `
        -CurrentPayloadRoot $currentPayloadRoot
    $existingPayloadManifestPath = Join-Path $currentPayloadRoot 'payload-manifest.json'
    if (-not (Test-Path -LiteralPath $existingPayloadManifestPath -PathType Leaf)) {
        throw 'Current payload manifest is missing for the supplied backup manifest.'
    }
    $existingPayloadManifest = Get-Content -LiteralPath $existingPayloadManifestPath -Raw |
        ConvertFrom-Json
}
elseif (Test-Path -LiteralPath $currentPayloadRoot -PathType Container) {
    $currentPayloadFiles = @(Get-ChildItem -LiteralPath $currentPayloadRoot -File -Force)
    if ($currentPayloadFiles.Count -gt 0) {
        throw 'PayloadBackupManifest is required when current payload files exist.'
    }
}

foreach ($requiredBuildFile in @(
        (Join-Path $projectRoot 'global.json'),
        (Join-Path $projectRoot 'NuGet.config')
    )) {
    Assert-SafeFilePath -Path $requiredBuildFile
    if (-not (Test-Path -LiteralPath $requiredBuildFile -PathType Leaf)) {
        throw "Required reproducibility file is missing: $requiredBuildFile"
    }
}
$lockFiles = @(Get-ChildItem -LiteralPath $projectRoot -Filter 'packages.lock.json' -File -Recurse |
    Where-Object { $_.FullName -notmatch '[\\/](bin|obj|dist|payload|runs|rollback|candidates)[\\/]' })
if ($lockFiles.Count -lt 3) {
    throw 'Expected project lock files are missing. Run the approved lockfile generation first.'
}

Assert-SafeFilePath -Path (Join-Path $projectRoot 'Directory.Build.props')
[xml]$buildProps = Get-Content -LiteralPath (Join-Path $projectRoot 'Directory.Build.props') -Raw
$productVersion = [string]$buildProps.Project.PropertyGroup.Version
if ([string]::IsNullOrWhiteSpace($productVersion)) {
    throw 'Product version is missing from Directory.Build.props.'
}
$project = Join-Path $projectRoot 'src\ImageCompressor.App\ImageCompressor.App.csproj'
Assert-SafeFilePath -Path $project
[xml]$appProject = Get-Content -LiteralPath $project -Raw
$runtimeFrameworkVersion = [string]$appProject.Project.PropertyGroup.RuntimeFrameworkVersion
if ([string]::IsNullOrWhiteSpace($runtimeFrameworkVersion)) {
    throw 'RuntimeFrameworkVersion must be pinned in ImageCompressor.App.csproj.'
}

$sourceDigest = Get-CanonicalSourceDigest `
    -ProjectRoot $projectRoot `
    -FacadeRoot $facadeRoot `
    -WorkspaceRoot $workspaceRoot
$buildId = 'sha256.{0}' -f $sourceDigest.Substring(0, 16).ToLowerInvariant()
$informationalVersion = "$productVersion+$buildId"

New-Item -ItemType Directory -Path $output | Out-Null
$payloadRoot = Join-Path $output 'payload'
$distRoot = Join-Path $output 'dist'
$distributionRoot = Join-Path $distRoot 'image-compressor-installer'
$distributionArchive = Join-Path $distRoot 'image-compressor-installer.zip'
$distributionManifest = Join-Path $distRoot 'image-compressor-installer.manifest.json'
$portableArchive = Join-Path $distRoot 'image-compressor-portable-win-x64.zip'
$workRoot = Join-Path $output '_work'
foreach ($directory in $payloadRoot, $distRoot, $distributionRoot, $workRoot) {
    $safeDirectory = Assert-PathWithinRoot -Path $directory -Root $output
    New-Item -ItemType Directory -Path $safeDirectory | Out-Null
}

$entryBatch = Join-Path $facadeRoot 'ここから開始 - Image Compressorを導入・更新.bat'
$installerScript = Join-Path $projectRoot 'installer\Install-ImageCompressor.ps1'
$packageReadme = Join-Path $projectRoot 'installer\README.md'
$appReadme = Join-Path $projectRoot 'installer\assets\README-portable.md'
$settings = Join-Path $projectRoot 'installer\assets\settings.json'
$settingsExample = Join-Path $projectRoot 'installer\assets\settings.example.json'
$legalFiles = [ordered]@{
    'LICENSE' = Join-Path $facadeRoot 'LICENSE'
    'DOTNET-LIBRARY-LICENSE.html' = Join-Path $projectRoot 'installer\assets\legal\DOTNET-LIBRARY-LICENSE.html'
    'DOTNET-LICENSE.txt' = Join-Path $projectRoot 'installer\assets\legal\DOTNET-LICENSE.txt'
    'DOTNET-THIRD-PARTY-NOTICES.txt' = Join-Path $projectRoot (
        'installer\assets\legal\DOTNET-THIRD-PARTY-NOTICES.txt')
    'WINDOWSDESKTOP-LICENSE.txt' = Join-Path $projectRoot (
        'installer\assets\legal\WINDOWSDESKTOP-LICENSE.txt')
}
$nugetConfig = Join-Path $projectRoot 'NuGet.config'
$payloads = [ordered]@{}
$buildArtifacts = Join-Path $workRoot 'artifacts'

foreach ($legalFile in $legalFiles.Values) {
    if (-not (Test-Path -LiteralPath $legalFile -PathType Leaf)) {
        throw "Required legal notice is missing: $legalFile"
    }
}

Push-Location $projectRoot
try {
    & dotnet restore $project `
        --locked-mode `
        --configfile $nugetConfig `
        --artifacts-path $buildArtifacts `
        --no-cache `
        --nologo
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet locked restore failed with exit code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

if ([string]::IsNullOrWhiteSpace($env:NUGET_PACKAGES)) {
    throw 'NUGET_PACKAGES must point to an isolated workspace-local package cache.'
}
$nugetPackagesRoot = Assert-PathWithinRoot -Path $env:NUGET_PACKAGES -Root $workspaceRoot
foreach ($runtime in 'win-x64', 'win-arm64') {
    $runtimePackRoot = Join-Path $nugetPackagesRoot (
        'microsoft.windowsdesktop.app.runtime.{0}\{1}' -f
        $runtime,
        $runtimeFrameworkVersion)
    $runtimeListPath = Join-Path $runtimePackRoot 'data\RuntimeList.xml'
    if (-not (Test-Path -LiteralPath $runtimeListPath -PathType Leaf)) {
        throw "WindowsDesktop runtime list is missing for $runtime`: $runtimeListPath"
    }
    Assert-SafeFilePath -Path $runtimeListPath
    [xml]$runtimeList = Get-Content -LiteralPath $runtimeListPath -Raw
    $missingRuntimeFiles = @(
        foreach ($runtimeFile in $runtimeList.FileList.File) {
            $declaredPath = [string]$runtimeFile.Path
            if ([string]::IsNullOrWhiteSpace($declaredPath)) {
                continue
            }
            $resolvedPath = Join-Path $runtimePackRoot $declaredPath
            if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
                $declaredPath
            }
        }
    )
    if ($missingRuntimeFiles.Count -gt 0) {
        throw "Incomplete WindowsDesktop runtime pack for $runtime $runtimeFrameworkVersion. Missing: $($missingRuntimeFiles -join ', ')"
    }
    $longestRuntimePath = @(
        foreach ($runtimeFile in $runtimeList.FileList.File) {
            $declaredPath = [string]$runtimeFile.Path
            if (-not [string]::IsNullOrWhiteSpace($declaredPath)) {
                [IO.Path]::GetFullPath((Join-Path $runtimePackRoot $declaredPath))
            }
        }
    ) | Sort-Object Length -Descending | Select-Object -First 1
    if ($longestRuntimePath.Length -gt 259) {
        throw "NUGET_PACKAGES is too deeply nested for MSBuild runtime-pack copy operations ($($longestRuntimePath.Length) characters): $longestRuntimePath"
    }
}

foreach ($definition in @(
        [pscustomobject]@{ Runtime = 'win-x64'; Machine = 0x8664 },
        [pscustomobject]@{ Runtime = 'win-arm64'; Machine = 0xAA64 }
    )) {
    $runtime = $definition.Runtime
    $publishDirectory = Join-Path $workRoot "publish-$runtime"
    Write-Host "==> Publish candidate $runtime ($informationalVersion)" -ForegroundColor Cyan
    Push-Location $projectRoot
    try {
        & dotnet publish $project `
            --configuration Release `
            --runtime $runtime `
            --self-contained true `
            --output $publishDirectory `
            --artifacts-path $buildArtifacts `
            --no-restore `
            --nologo `
            -p:PublishSingleFile=true `
            -p:IncludeNativeLibrariesForSelfExtract=true `
            -p:ContinuousIntegrationBuild=true `
            -p:EnableSourceControlManagerQueries=false `
            -p:IncludeSourceRevisionInInformationalVersion=false `
            "-p:InformationalVersion=$informationalVersion" `
            -p:DebugType=None `
            -p:DebugSymbols=false
        if ($LASTEXITCODE -ne 0) {
            throw "dotnet publish $runtime failed with exit code $LASTEXITCODE"
        }
    }
    finally {
        Pop-Location
    }

    $symbols = @(Get-ChildItem -LiteralPath $publishDirectory -Filter '*.pdb' -File)
    if ($symbols.Count -ne 0) {
        throw "Public payload unexpectedly contains debug symbols for $runtime."
    }

    Copy-Item -LiteralPath $appReadme -Destination (Join-Path $publishDirectory 'README.md')
    Copy-Item -LiteralPath $settings -Destination (Join-Path $publishDirectory 'settings.json')
    Copy-Item -LiteralPath $settingsExample -Destination (Join-Path $publishDirectory 'settings.example.json')
    foreach ($legalFile in $legalFiles.GetEnumerator()) {
        Copy-Item `
            -LiteralPath $legalFile.Value `
            -Destination (Join-Path $publishDirectory $legalFile.Key)
    }

    $expectedNames = @(
        'LICENSE',
        'DOTNET-LIBRARY-LICENSE.html',
        'DOTNET-LICENSE.txt',
        'DOTNET-THIRD-PARTY-NOTICES.txt',
        'ImageCompressor.App.exe',
        'README.md',
        'settings.example.json',
        'settings.json',
        'WINDOWSDESKTOP-LICENSE.txt'
    )
    $actualNames = @(Get-ChildItem -LiteralPath $publishDirectory -File |
        Select-Object -ExpandProperty Name |
        Sort-Object)
    if (Compare-Object -ReferenceObject ($expectedNames | Sort-Object) -DifferenceObject $actualNames) {
        throw "Unexpected files were produced for $runtime`: $($actualNames -join ', ')"
    }

    $executable = Join-Path $publishDirectory 'ImageCompressor.App.exe'
    if (Test-FileContainsUtf8Text -Path $executable -Text $workspaceRoot) {
        throw "Published executable contains a local workspace path for $runtime."
    }
    $machine = Get-PeMachine -Path $executable
    if ($machine -ne $definition.Machine) {
        throw ('PE architecture mismatch for {0}. Expected 0x{1:X4}, actual 0x{2:X4}.' -f
            $runtime, $definition.Machine, $machine)
    }

    $managedFiles = @(
        foreach ($name in @(
                'LICENSE',
                'DOTNET-LIBRARY-LICENSE.html',
        'DOTNET-LICENSE.txt',
                'DOTNET-THIRD-PARTY-NOTICES.txt',
                'ImageCompressor.App.exe',
                'README.md',
                'settings.example.json',
                'WINDOWSDESKTOP-LICENSE.txt'
            )) {
            Get-FileRecord -Path (Join-Path $publishDirectory $name) -Name $name
        }
    )
    $seedFiles = @(
        Get-FileRecord -Path (Join-Path $publishDirectory 'settings.json') -Name 'settings.json'
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
        userOwnedSeedFiles = $seedFiles
    }
}

$sameVersionContentChanged = $null -ne $existingPayloadManifest -and
    $productVersion -eq [string]$existingPayloadManifest.productVersion -and
    -not (Test-SameVersionContent `
        -ExistingManifest $existingPayloadManifest `
        -CandidatePayloads $payloads)
if ($sameVersionContentChanged -and -not $AllowUnpublishedSameVersionRebuild) {
    throw "Managed payload content changed without a product version change ($productVersion)."
}

$payloadManifestPath = Join-Path $payloadRoot 'payload-manifest.json'
Write-JsonFile -Path $payloadManifestPath -Value ([ordered]@{
        schemaVersion = 1
        productId = 'image-compressor'
        productName = 'Image Compressor'
        productVersion = $productVersion
        runtimeFrameworkVersion = $runtimeFrameworkVersion
        buildId = $buildId
        sourceDigest = $sourceDigest
        createdAt = [DateTimeOffset]::Now.ToString('o')
        payloads = $payloads
    })

Copy-Item -LiteralPath (Join-Path $facadeRoot 'LICENSE') -Destination (Join-Path $distributionRoot 'LICENSE')
Copy-Item -LiteralPath $entryBatch -Destination $distributionRoot
Copy-Item -LiteralPath $packageReadme -Destination (Join-Path $distributionRoot 'README.md')
$distributionInstaller = Join-Path $distributionRoot 'installer'
$distributionPayload = Join-Path $distributionInstaller 'payload'
New-Item -ItemType Directory -Path $distributionPayload -Force | Out-Null
Copy-Item -LiteralPath $installerScript -Destination $distributionInstaller
foreach ($payloadFile in Get-ChildItem -LiteralPath $payloadRoot -File) {
    Copy-Item -LiteralPath $payloadFile.FullName -Destination $distributionPayload
}

Compress-Archive `
    -Path (Join-Path $distributionRoot '*') `
    -DestinationPath $distributionArchive `
    -CompressionLevel Optimal
Copy-Item `
    -LiteralPath (Join-Path $payloadRoot 'ImageCompressor-win-x64.zip') `
    -Destination $portableArchive

$distributionFiles = @(
    Get-ChildItem -LiteralPath $distributionRoot -File -Recurse |
        Sort-Object FullName |
        ForEach-Object {
            Get-FileRecord `
                -Path $_.FullName `
                -Name ([IO.Path]::GetRelativePath($distributionRoot, $_.FullName))
        }
)
Write-JsonFile -Path $distributionManifest -Value ([ordered]@{
        schemaVersion = 1
        productId = 'image-compressor'
        productVersion = $productVersion
        runtimeFrameworkVersion = $runtimeFrameworkVersion
        buildId = $buildId
        sourceDigest = $sourceDigest
        createdAt = [DateTimeOffset]::Now.ToString('o')
        archive = [IO.Path]::GetFileName($distributionArchive)
        archiveBytes = (Get-Item -LiteralPath $distributionArchive).Length
        archiveSha256 = (Get-FileHash -LiteralPath $distributionArchive -Algorithm SHA256).Hash
        portableArchive = [IO.Path]::GetFileName($portableArchive)
        portableArchiveBytes = (Get-Item -LiteralPath $portableArchive).Length
        portableArchiveSha256 = (Get-FileHash -LiteralPath $portableArchive -Algorithm SHA256).Hash
        files = $distributionFiles
    })

$safeWorkRoot = Assert-PathWithinRoot -Path $workRoot -Root $output
Assert-NotReparsePoint -Path $safeWorkRoot
Remove-Item -LiteralPath $safeWorkRoot -Recurse -Force

$candidateFiles = @(
    Get-ChildItem -LiteralPath $output -File -Recurse |
        Sort-Object FullName |
        ForEach-Object {
            Get-FileRecord `
                -Path $_.FullName `
                -Name ([IO.Path]::GetRelativePath($output, $_.FullName))
        }
)
$candidateReceipt = Join-Path $output 'candidate-receipt.json'
Write-JsonFile -Path $candidateReceipt -Value ([ordered]@{
        schemaVersion = 1
        productId = 'image-compressor'
        productVersion = $productVersion
        runtimeFrameworkVersion = $runtimeFrameworkVersion
        buildId = $buildId
        sourceDigest = $sourceDigest
        createdAt = [DateTimeOffset]::Now.ToString('o')
        promoted = $false
        payloadBaselineMode = if ($null -ne $backup) {
            'verified-existing-payload'
        }
        else {
            'clean-source'
        }
        previousPayloadVersion = if ($null -ne $backup) {
            [string]$backup.ProductVersion
        }
        else {
            $null
        }
        payloadBackupManifest = if ($null -ne $backup) {
            [IO.Path]::GetRelativePath(
                $workspaceRoot,
                $backup.ManifestPath).Replace('\', '/')
        }
        else {
            $null
        }
        unpublishedSameVersionRebuild = [bool](
            $sameVersionContentChanged -and $AllowUnpublishedSameVersionRebuild)
        files = $candidateFiles
    })

Write-Host "Candidate root: $output" -ForegroundColor Green
Write-Host "Candidate receipt: $candidateReceipt" -ForegroundColor Green
Write-Host 'No existing payload or dist files were modified.' -ForegroundColor Yellow
