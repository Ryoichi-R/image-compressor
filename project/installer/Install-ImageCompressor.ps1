<#
.SYNOPSIS
    Safely installs or updates a prebuilt Image Compressor payload.

.DESCRIPTION
    Uses temporary staging, validation, one-generation backup, running-process
    rejection, a mutex, and automatic rollback. User-owned files are preserved.
#>
[CmdletBinding()]
param(
    [ValidateSet('auto', 'win-x64', 'win-arm64')]
    [string]$Runtime = 'auto',
    [switch]$DetectRuntimeOnly,
    [string]$OutputRoot,
    [switch]$OutputRootFromEnvironment,
    [switch]$SelectOutputRoot,
    [switch]$RevealOutput,
    [string]$PackageRoot,
    [string]$InstallerStateRoot,
    [ValidateRange(0, 100)]
    [int]$TestFailAfterManagedFileCount = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$productId = 'image-compressor'
$productFolderName = 'Image Compressor'
$markerName = '.image-compressor-install.json'
$settingsName = 'settings.json'
$executableName = 'ImageCompressor.App.exe'

function ConvertTo-ImageCompressorRuntime {
    param([Parameter(Mandatory)][ushort]$NativeMachine)

    switch ($NativeMachine) {
        0x8664 { return 'win-x64' }
        0xAA64 { return 'win-arm64' }
        default { throw ('Unsupported native Windows architecture: 0x{0:X4}' -f $NativeMachine) }
    }
}

function Get-ImageCompressorNativeMachine {
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw 'Native architecture detection requires Windows.'
    }
    if (-not ('ImageCompressor.Installer.NativeArchitecture' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace ImageCompressor.Installer {
    public static class NativeArchitecture {
        [DllImport("kernel32.dll")] private static extern IntPtr GetCurrentProcess();
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool IsWow64Process2(IntPtr process, out ushort processMachine, out ushort nativeMachine);
        public static ushort Read() {
            ushort processMachine;
            ushort nativeMachine;
            if (!IsWow64Process2(GetCurrentProcess(), out processMachine, out nativeMachine)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return nativeMachine;
        }
    }
}
'@
    }
    return [ImageCompressor.Installer.NativeArchitecture]::Read()
}

function Get-ImageCompressorNativeRuntime {
    try {
        $nativeMachine = Get-ImageCompressorNativeMachine
        return ConvertTo-ImageCompressorRuntime -NativeMachine $nativeMachine
    }
    catch {
        throw "Unable to determine a supported native Windows architecture. Installation stopped: $($_.Exception.Message)"
    }
}

function Get-NormalizedDirectoryPath {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $pathRoot = [IO.Path]::GetPathRoot($fullPath)
    if ($fullPath.Equals($pathRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $pathRoot
    }
    return $fullPath.TrimEnd(
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
    $rootPrefix = if ($rootFull.EndsWith(
            [IO.Path]::DirectorySeparatorChar.ToString(),
            [StringComparison]::Ordinal)) {
        $rootFull
    }
    else {
        $rootFull + [IO.Path]::DirectorySeparatorChar
    }
    if ($pathFull -ne $rootFull -and
        -not $pathFull.StartsWith(
            $rootPrefix,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to operate outside the allowed root: $pathFull"
    }
    return $pathFull
}

function Assert-ManagedDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ExpectedLeaf
    )

    $pathFull = Assert-PathWithinRoot -Path $Path -Root $Root
    if ((Split-Path -Leaf $pathFull) -cne $ExpectedLeaf) {
        throw "Refusing to manage an unexpected directory: $pathFull"
    }
    if (Test-Path -LiteralPath $pathFull) {
        if (-not (Test-Path -LiteralPath $pathFull -PathType Container)) {
            throw "Managed path exists but is not a directory: $pathFull"
        }
        if ((Get-Item -LiteralPath $pathFull -Force).Attributes -band
            [IO.FileAttributes]::ReparsePoint) {
            throw "Managed directory cannot be a symbolic link or junction: $pathFull"
        }
    }
    return $pathFull
}

function Assert-SafeFileName {
    param([Parameter(Mandatory)][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name) -or
        $Name -ne [IO.Path]::GetFileName($Name) -or
        [IO.Path]::IsPathRooted($Name) -or
        $Name -in '.', '..') {
        throw "Payload contains an unsafe file name: $Name"
    }
    return $Name
}

function Get-StableHashText {
    param([Parameter(Mandatory)][string]$Value)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
        $stream.Dispose()
    }
}

function Get-PeMachine {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = [IO.BinaryReader]::new($stream)
        $stream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0 -or $peOffset + 6 -gt $stream.Length) {
            throw "Invalid PE header offset: $Path"
        }
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

function Select-OutputRootFolder {
    param([Parameter(Mandatory)][string]$InitialDirectory)

    $apartmentState = ([Threading.Thread]::CurrentThread).GetApartmentState()
    if ($apartmentState -ne [Threading.ApartmentState]::STA) {
        throw 'PowerShell must run with -STA to show the folder picker.'
    }

    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    try {
        $dialog.Description = 'Select the parent folder. The installer will create an Image Compressor subfolder.'
        if ($dialog.PSObject.Properties['UseDescriptionForTitle']) {
            $dialog.UseDescriptionForTitle = $true
        }
        if ($dialog.PSObject.Properties['AutoUpgradeEnabled']) {
            $dialog.AutoUpgradeEnabled = $true
        }
        $dialog.ShowNewFolderButton = $true
        $dialog.SelectedPath = $InitialDirectory
        $result = $dialog.ShowDialog()
        if ($result -ne [Windows.Forms.DialogResult]::OK -or
            [string]::IsNullOrWhiteSpace($dialog.SelectedPath)) {
            Write-Host 'Folder selection was cancelled. No files were changed.' -ForegroundColor Yellow
            exit 3
        }
        return $dialog.SelectedPath
    }
    finally {
        $dialog.Dispose()
    }
}

function Clear-ManagedDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AllowedRoot,
        [Parameter(Mandatory)][string]$ExpectedLeaf
    )

    $safe = Assert-ManagedDirectory -Path $Path -Root $AllowedRoot -ExpectedLeaf $ExpectedLeaf
    New-Item -ItemType Directory -Path $safe -Force | Out-Null
    foreach ($child in Get-ChildItem -LiteralPath $safe -Force) {
        $safeChild = Assert-PathWithinRoot -Path $child.FullName -Root $safe
        Remove-Item -LiteralPath $safeChild -Recurse -Force
    }
}

function Copy-FileVerified {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    $safeDestination = Assert-PathWithinRoot -Path $Destination -Root $DestinationRoot
    $temporaryName = '.image-compressor-install-{0}.tmp' -f [guid]::NewGuid().ToString('N')
    $temporary = Assert-PathWithinRoot -Path (Join-Path $DestinationRoot $temporaryName) -Root $DestinationRoot
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary -Force
        if ((Get-FileSha256 -Path $Source) -ne
            (Get-FileSha256 -Path $temporary)) {
            throw "Copy verification failed: $safeDestination"
        }
        Move-Item -LiteralPath $temporary -Destination $safeDestination -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root
    )

    $safePath = Assert-PathWithinRoot -Path $Path -Root $Root
    $temporaryName = '.image-compressor-manifest-{0}.tmp' -f [guid]::NewGuid().ToString('N')
    $temporary = Assert-PathWithinRoot -Path (Join-Path $Root $temporaryName) -Root $Root
    try {
        $Value | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $temporary -Encoding UTF8
        $null = Get-Content -LiteralPath $temporary -Raw | ConvertFrom-Json
        Move-Item -LiteralPath $temporary -Destination $safePath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-InstalledProcess {
    param([Parameter(Mandatory)][string]$ExecutablePath)

    $expected = [IO.Path]::GetFullPath($ExecutablePath)
    $processIds = [Collections.Generic.List[int]]::new()
    foreach ($process in [Diagnostics.Process]::GetProcesses()) {
        try {
            $path = $process.MainModule.FileName
            if ($path -and [IO.Path]::GetFullPath($path).Equals(
                    $expected,
                    [StringComparison]::OrdinalIgnoreCase)) {
                $processIds.Add($process.Id)
            }
        }
        catch {
            # A process that cannot expose its executable path is not assumed
            # to be the managed target. The subsequent atomic replace remains
            # protected by Windows file locking and rollback.
        }
        finally {
            $process.Dispose()
        }
    }
    return $processIds.ToArray()
}

function Test-ExecutableLocked {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $stream = $null
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None)
        return $false
    }
    catch [IO.IOException] {
        return $true
    }
    catch [UnauthorizedAccessException] {
        return $true
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Get-CurrentInstallState {
    param(
        [Parameter(Mandatory)][string]$InstallDirectory,
        [Parameter(Mandatory)][string]$MarkerPath
    )

    if (-not (Test-Path -LiteralPath $InstallDirectory)) {
        return $null
    }
    $items = @(Get-ChildItem -LiteralPath $InstallDirectory -Force)
    if ($items.Count -eq 0) {
        return $null
    }
    if (Test-Path -LiteralPath $MarkerPath -PathType Leaf) {
        $state = Get-Content -LiteralPath $MarkerPath -Raw | ConvertFrom-Json
        if ($state.productId -ne $productId) {
            throw "Install marker belongs to another product: $MarkerPath"
        }
        return $state
    }

    $legacyExe = Join-Path $InstallDirectory $executableName
    if (-not (Test-Path -LiteralPath $legacyExe -PathType Leaf)) {
        throw "The existing '$productFolderName' folder is not a recognized installation. Move it aside or select another parent folder."
    }
    $legacyAllowed = @(
        $executableName,
        'ImageCompressor.App.pdb',
        'ImageCompressor.Domain.pdb',
        'ImageCompressor.Infrastructure.pdb',
        'README.md',
        'settings.example.json',
        $settingsName
    )
    $unknown = @($items | Where-Object {
            $_.PSIsContainer -or $_.Name -notin $legacyAllowed
        })
    if ($unknown.Count -gt 0) {
        throw "Markerless installation contains unknown files and will not be adopted: $($unknown[0].FullName)"
    }
    $legacyManaged = @($items | Where-Object {
            -not $_.PSIsContainer -and $_.Name -ne $settingsName
        } | ForEach-Object {
            [pscustomobject]@{
                name = $_.Name
                sha256 = Get-FileSha256 -Path $_.FullName
            }
        })
    return [pscustomobject]@{
        schemaVersion = 1
        productId = $productId
        productVersion = 'legacy'
        runtime = 'unknown'
        installedAt = $null
        managedFiles = $legacyManaged
    }
}

function Copy-CurrentInstallToBackup {
    param(
        [Parameter(Mandatory)]$CurrentState,
        [Parameter(Mandatory)][string]$InstallDirectory,
        [Parameter(Mandatory)][string]$BackupDirectory,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$BackupLeaf,
        [Parameter(Mandatory)][string]$MarkerPath
    )

    Clear-ManagedDirectory -Path $BackupDirectory -AllowedRoot $BackupRoot -ExpectedLeaf $BackupLeaf
    foreach ($entry in @($CurrentState.managedFiles)) {
        $name = Assert-SafeFileName -Name ([string]$entry.name)
        $source = Assert-PathWithinRoot -Path (Join-Path $InstallDirectory $name) -Root $InstallDirectory
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination (Join-Path $BackupDirectory $name) -Force
            if ((Get-FileSha256 -Path $source) -ne
                (Get-FileSha256 -Path (Join-Path $BackupDirectory $name))) {
                throw "Backup verification failed: $name"
            }
        }
    }
    if (Test-Path -LiteralPath $MarkerPath -PathType Leaf) {
        Copy-Item -LiteralPath $MarkerPath -Destination (Join-Path $BackupDirectory $markerName) -Force
    }
    else {
        $legacyMarker = Join-Path $BackupDirectory $markerName
        $CurrentState | ConvertTo-Json -Depth 8 |
            Set-Content -LiteralPath $legacyMarker -Encoding UTF8
    }
}

function Restore-Backup {
    param(
        [Parameter(Mandatory)][string]$InstallDirectory,
        [Parameter(Mandatory)][string]$BackupDirectory,
        [Parameter(Mandatory)][string[]]$NewManagedFiles,
        [Parameter(Mandatory)][bool]$RemoveCreatedSettings
    )

    foreach ($name in @($NewManagedFiles + $markerName)) {
        $safeName = Assert-SafeFileName -Name $name
        $target = Assert-PathWithinRoot -Path (Join-Path $InstallDirectory $safeName) -Root $InstallDirectory
        if (Test-Path -LiteralPath $target -PathType Leaf) {
            Remove-Item -LiteralPath $target -Force
        }
    }
    if ($RemoveCreatedSettings) {
        $settingsPath = Assert-PathWithinRoot -Path (Join-Path $InstallDirectory $settingsName) -Root $InstallDirectory
        if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
            Remove-Item -LiteralPath $settingsPath -Force
        }
    }
    foreach ($file in Get-ChildItem -LiteralPath $BackupDirectory -File -Force) {
        Copy-FileVerified `
            -Source $file.FullName `
            -Destination (Join-Path $InstallDirectory $file.Name) `
            -DestinationRoot $InstallDirectory
    }
}

if ($Runtime -eq 'auto' -or $DetectRuntimeOnly) {
    $Runtime = Get-ImageCompressorNativeRuntime
}
if ($DetectRuntimeOnly) {
    # Read-only diagnostic: do not read payloads, select folders, or create state.
    Write-Output $Runtime
    return
}

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    $PackageRoot = Split-Path -Parent $PSScriptRoot
}
$packageFull = Get-NormalizedDirectoryPath -Path $PackageRoot
$installerRoot = Assert-PathWithinRoot -Path $PSScriptRoot -Root $packageFull
$payloadRoot = Assert-ManagedDirectory `
    -Path (Join-Path $installerRoot 'payload') `
    -Root $installerRoot `
    -ExpectedLeaf 'payload'
$payloadManifestPath = Assert-PathWithinRoot `
    -Path (Join-Path $payloadRoot 'payload-manifest.json') `
    -Root $payloadRoot
if (-not (Test-Path -LiteralPath $payloadManifestPath -PathType Leaf)) {
    throw "Payload manifest is missing: $payloadManifestPath"
}
$payloadManifest = Get-Content -LiteralPath $payloadManifestPath -Raw | ConvertFrom-Json
if ($payloadManifest.schemaVersion -ne 1 -or $payloadManifest.productId -ne $productId) {
    throw 'Payload manifest schema or product id is invalid.'
}
$payloadProperty = $payloadManifest.payloads.PSObject.Properties[$Runtime]
if ($null -eq $payloadProperty) {
    throw "No prebuilt payload is available for $Runtime."
}
$payload = $payloadProperty.Value
$archiveName = Assert-SafeFileName -Name ([string]$payload.archive)
$archivePath = Assert-PathWithinRoot -Path (Join-Path $payloadRoot $archiveName) -Root $payloadRoot
if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
    throw "Payload archive is missing: $archivePath"
}
if ((Get-FileSha256 -Path $archivePath) -ne
    [string]$payload.sha256) {
    throw "Payload archive SHA-256 mismatch: $archiveName"
}

if ($OutputRootFromEnvironment) {
    $OutputRoot = [Environment]::GetEnvironmentVariable('IMAGE_COMPRESSOR_INSTALL_ROOT')
}
if ($SelectOutputRoot -and [string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Select-OutputRootFolder -InitialDirectory ([Environment]::GetFolderPath(
            [Environment+SpecialFolder]::DesktopDirectory))
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    throw 'Specify the installation parent folder.'
}
if ($OutputRoot -notmatch '^[A-Za-z]:[\\/]') {
    $OutputRoot = Join-Path $packageFull $OutputRoot
}
$outputRootFull = Get-NormalizedDirectoryPath -Path $OutputRoot
if ($outputRootFull.StartsWith('\\', [StringComparison]::Ordinal)) {
    throw 'UNC paths are not supported. Use a drive-letter path.'
}
if (-not (Test-Path -LiteralPath $outputRootFull -PathType Container)) {
    throw "Installation parent folder does not exist: $outputRootFull"
}
if ((Get-Item -LiteralPath $outputRootFull -Force).Attributes -band
    [IO.FileAttributes]::ReparsePoint) {
    throw "Installation parent cannot be a symbolic link or junction: $outputRootFull"
}
if ((Split-Path -Leaf $outputRootFull) -ieq $productFolderName) {
    throw "Select the parent folder of '$productFolderName', not the application folder itself."
}

$installDirectory = Assert-ManagedDirectory `
    -Path (Join-Path $outputRootFull $productFolderName) `
    -Root $outputRootFull `
    -ExpectedLeaf $productFolderName
$markerPath = Assert-PathWithinRoot -Path (Join-Path $installDirectory $markerName) -Root $installDirectory
$settingsPath = Assert-PathWithinRoot -Path (Join-Path $installDirectory $settingsName) -Root $installDirectory
$installedExe = Assert-PathWithinRoot -Path (Join-Path $installDirectory $executableName) -Root $installDirectory

$installHash = (Get-StableHashText -Value $installDirectory.ToUpperInvariant()).Substring(0, 16)
$temporaryRoot = Get-NormalizedDirectoryPath -Path ([IO.Path]::GetTempPath())
$stagingParentLeaf = "ImageCompressorInstaller-$installHash"
$stagingParent = Assert-ManagedDirectory `
    -Path (Join-Path $temporaryRoot $stagingParentLeaf) `
    -Root $temporaryRoot `
    -ExpectedLeaf $stagingParentLeaf
$stagingLeaf = '.staging-{0}' -f [guid]::NewGuid().ToString('N')
$stagingDirectory = Assert-ManagedDirectory `
    -Path (Join-Path $stagingParent $stagingLeaf) `
    -Root $stagingParent `
    -ExpectedLeaf $stagingLeaf

$localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
if ([string]::IsNullOrWhiteSpace($InstallerStateRoot)) {
    $backupRootLeaf = 'ImageCompressorInstaller'
    $installerStateRoot = Assert-ManagedDirectory `
        -Path (Join-Path $localAppData $backupRootLeaf) `
        -Root $localAppData `
        -ExpectedLeaf $backupRootLeaf
}
else {
    if ($InstallerStateRoot -notmatch '^[A-Za-z]:[\\/]') {
        throw 'InstallerStateRoot must be an absolute drive-letter path.'
    }
    $stateParent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($InstallerStateRoot))
    $stateLeaf = Split-Path -Leaf ([IO.Path]::GetFullPath($InstallerStateRoot))
    $installerStateRoot = Assert-ManagedDirectory `
        -Path $InstallerStateRoot `
        -Root $stateParent `
        -ExpectedLeaf $stateLeaf
}
$backupsRoot = Assert-ManagedDirectory `
    -Path (Join-Path $installerStateRoot 'Backups') `
    -Root $installerStateRoot `
    -ExpectedLeaf 'Backups'
$backupLeaf = "backup-$installHash"
$backupDirectory = Assert-ManagedDirectory `
    -Path (Join-Path $backupsRoot $backupLeaf) `
    -Root $backupsRoot `
    -ExpectedLeaf $backupLeaf

$mutex = [Threading.Mutex]::new($false, "Local\ImageCompressor-Installer-$installHash")
$lockTaken = $false
$backupPrepared = $false
$settingsCreated = $false
$installDirectoryCreated = $false
$applyStarted = $false
$newManagedNames = @()

try {
    try {
        $lockTaken = $mutex.WaitOne(0)
    }
    catch [Threading.AbandonedMutexException] {
        $lockTaken = $true
    }
    if (-not $lockTaken) {
        throw 'Another Image Compressor installation/update is already running for this destination.'
    }

    $currentState = Get-CurrentInstallState `
        -InstallDirectory $installDirectory `
        -MarkerPath $markerPath
    $running = @(Get-InstalledProcess -ExecutablePath $installedExe)
    if ($running.Count -gt 0 -or (Test-ExecutableLocked -Path $installedExe)) {
        throw 'Image Compressor is running from the update target. Close ImageCompressor.App.exe, then run this installer again.'
    }

    New-Item -ItemType Directory -Path $stagingParent -Force | Out-Null
    New-Item -ItemType Directory -Path $stagingDirectory -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        $entryNames = @($archive.Entries | Where-Object { -not [string]::IsNullOrEmpty($_.Name) } |
            ForEach-Object { Assert-SafeFileName -Name $_.FullName })
        $expectedNames = @($payload.managedFiles | ForEach-Object {
                Assert-SafeFileName -Name ([string]$_.name)
            }) + $settingsName
        $duplicates = @($entryNames | Group-Object | Where-Object Count -gt 1)
        if ($duplicates.Count -gt 0 -or
            @($entryNames | Where-Object { $_ -notin $expectedNames }).Count -gt 0 -or
            @($expectedNames | Where-Object { $_ -notin $entryNames }).Count -gt 0) {
            throw 'Payload archive entries do not match the signed manifest.'
        }
        [IO.Compression.ZipFileExtensions]::ExtractToDirectory($archive, $stagingDirectory)
    }
    finally {
        $archive.Dispose()
    }

    $newManagedNames = @($payload.managedFiles | ForEach-Object {
            Assert-SafeFileName -Name ([string]$_.name)
        })
    foreach ($entry in @($payload.managedFiles)) {
        $name = Assert-SafeFileName -Name ([string]$entry.name)
        $stagedFile = Assert-PathWithinRoot -Path (Join-Path $stagingDirectory $name) -Root $stagingDirectory
        if ((Get-FileSha256 -Path $stagedFile) -ne
            [string]$entry.sha256) {
            throw "Staged payload SHA-256 mismatch: $name"
        }
    }
    $stagedSettings = Assert-PathWithinRoot -Path (Join-Path $stagingDirectory $settingsName) -Root $stagingDirectory
    $null = Get-Content -LiteralPath $stagedSettings -Raw | ConvertFrom-Json
    $stagedExe = Assert-PathWithinRoot -Path (Join-Path $stagingDirectory $executableName) -Root $stagingDirectory
    if ((Get-FileSha256 -Path $stagedExe) -ne
        [string]$payload.executableSha256) {
        throw 'Executable SHA-256 does not match the payload manifest.'
    }
    $expectedMachine = if ($Runtime -eq 'win-arm64') { 0xAA64 } else { 0x8664 }
    $actualMachine = Get-PeMachine -Path $stagedExe
    if ($actualMachine -ne $expectedMachine -or $actualMachine -ne [int]$payload.peMachine) {
        throw ('Payload architecture mismatch. Runtime={0}, expected=0x{1:X4}, actual=0x{2:X4}.' -f
            $Runtime, $expectedMachine, $actualMachine)
    }

    if ($null -ne $currentState) {
        New-Item -ItemType Directory -Path $backupsRoot -Force | Out-Null
        Copy-CurrentInstallToBackup `
            -CurrentState $currentState `
            -InstallDirectory $installDirectory `
            -BackupDirectory $backupDirectory `
            -BackupRoot $backupsRoot `
            -BackupLeaf $backupLeaf `
            -MarkerPath $markerPath
        $backupPrepared = $true
    }

    $applyStarted = $true
    if (-not (Test-Path -LiteralPath $installDirectory)) {
        New-Item -ItemType Directory -Path $installDirectory | Out-Null
        $installDirectoryCreated = $true
    }
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        Copy-FileVerified `
            -Source $stagedSettings `
            -Destination $settingsPath `
            -DestinationRoot $installDirectory
        $settingsCreated = $true
    }

    $copied = 0
    foreach ($entry in @($payload.managedFiles)) {
        $name = Assert-SafeFileName -Name ([string]$entry.name)
        Copy-FileVerified `
            -Source (Join-Path $stagingDirectory $name) `
            -Destination (Join-Path $installDirectory $name) `
            -DestinationRoot $installDirectory
        $copied++
        if ($TestFailAfterManagedFileCount -gt 0 -and
            $copied -ge $TestFailAfterManagedFileCount) {
            throw "Test-only simulated update failure after $copied managed file(s)."
        }
    }

    if ($null -ne $currentState) {
        $oldNames = @($currentState.managedFiles | ForEach-Object {
                Assert-SafeFileName -Name ([string]$_.name)
            })
        foreach ($oldName in $oldNames | Where-Object { $_ -notin $newManagedNames }) {
            $obsolete = Assert-PathWithinRoot -Path (Join-Path $installDirectory $oldName) -Root $installDirectory
            if (Test-Path -LiteralPath $obsolete -PathType Leaf) {
                Remove-Item -LiteralPath $obsolete -Force
            }
        }
    }

    $installedAt = if ($null -ne $currentState -and $currentState.installedAt) {
        [string]$currentState.installedAt
    }
    else {
        [DateTimeOffset]::Now.ToString('o')
    }
    $installedManifest = [ordered]@{
        schemaVersion = 1
        productId = $productId
        productVersion = [string]$payloadManifest.productVersion
        runtime = $Runtime
        installedAt = $installedAt
        updatedAt = [DateTimeOffset]::Now.ToString('o')
        executable = $executableName
        userOwnedFiles = @($settingsName)
        managedFiles = @($payload.managedFiles)
    }
    Write-JsonAtomic -Value $installedManifest -Path $markerPath -Root $installDirectory

    foreach ($entry in @($payload.managedFiles)) {
        $installed = Join-Path $installDirectory ([string]$entry.name)
        if ((Get-FileSha256 -Path $installed) -ne
            [string]$entry.sha256) {
            throw "Installed payload verification failed: $($entry.name)"
        }
    }
    if (-not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
        throw 'Portable settings file is missing after installation.'
    }

    Write-Host "Image Compressor $Runtime was installed or updated successfully." -ForegroundColor Green
    Write-Host "Install folder: $installDirectory" -ForegroundColor Green
    Write-Host "Executable: $installedExe" -ForegroundColor Green
    Write-Host 'The application was not started automatically.' -ForegroundColor Cyan
    if ($backupPrepared) {
        Write-Host "One previous managed generation is retained at: $backupDirectory" -ForegroundColor Yellow
    }
    if ($RevealOutput) {
        try {
            Start-Process -FilePath 'explorer.exe' -ArgumentList @($installDirectory) | Out-Null
        }
        catch {
            Write-Warning "Could not open the install folder automatically: $installDirectory"
        }
    }
}
catch {
    $originalError = $_
    try {
        if ($applyStarted -and
            (Test-Path -LiteralPath $installDirectory -PathType Container)) {
            if ($backupPrepared) {
                Restore-Backup `
                    -InstallDirectory $installDirectory `
                    -BackupDirectory $backupDirectory `
                    -NewManagedFiles $newManagedNames `
                    -RemoveCreatedSettings $settingsCreated
                Write-Host 'The previous managed installation was restored.' -ForegroundColor Yellow
            }
            else {
                foreach ($name in @($newManagedNames + $markerName)) {
                    $safeName = Assert-SafeFileName -Name $name
                    $path = Assert-PathWithinRoot -Path (Join-Path $installDirectory $safeName) -Root $installDirectory
                    if (Test-Path -LiteralPath $path -PathType Leaf) {
                        Remove-Item -LiteralPath $path -Force
                    }
                }
                if ($settingsCreated -and (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
                    Remove-Item -LiteralPath $settingsPath -Force
                }
                if ($installDirectoryCreated -and
                    @(Get-ChildItem -LiteralPath $installDirectory -Force).Count -eq 0) {
                    Remove-Item -LiteralPath $installDirectory -Force
                }
            }
        }
    }
    catch {
        Write-Error "Automatic rollback also failed: $($_.Exception.Message)"
    }
    throw $originalError
}
finally {
    if (Test-Path -LiteralPath $stagingDirectory) {
        $safeStaging = Assert-ManagedDirectory `
            -Path $stagingDirectory `
            -Root $stagingParent `
            -ExpectedLeaf $stagingLeaf
        Remove-Item -LiteralPath $safeStaging -Recurse -Force
    }
    if ((Test-Path -LiteralPath $stagingParent) -and
        @(Get-ChildItem -LiteralPath $stagingParent -Force).Count -eq 0) {
        Remove-Item -LiteralPath $stagingParent -Force
    }
    if ($lockTaken) {
        $mutex.ReleaseMutex()
    }
    $mutex.Dispose()
}
