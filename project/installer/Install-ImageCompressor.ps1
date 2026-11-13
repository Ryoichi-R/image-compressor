<#
.SYNOPSIS
    Safely installs or updates a prebuilt Image Compressor payload.

.DESCRIPTION
    Uses temporary staging, validation, verified backup, running-process
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
    [int]$TestFailAfterManagedFileCount = 0,
    [scriptblock]$TestBeforeOperation
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
        $Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        $Name.EndsWith('.') -or $Name.EndsWith(' ') -or
        $Name -match '^(CON|PRN|AUX|NUL|COM[1-9\u00b9\u00b2\u00b3]|LPT[1-9\u00b9\u00b2\u00b3])(\.|$)') {
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

function Get-ExistingEntry {
    param([Parameter(Mandatory)][string]$Path)

    try {
        return Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        return $null
    }
}

function Assert-RegularFile {
    param([Parameter(Mandatory)]$Entry)

    if ($Entry.PSIsContainer -or ($Entry.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Expected a regular file: $($Entry.FullName)"
    }
}

function Assert-FileState {
    param([Parameter(Mandatory)][string]$Path, [string]$ExpectedHash)

    $entry = Get-ExistingEntry -Path $Path
    if ($ExpectedHash) {
        if ($null -eq $entry) {
            throw "Expected file is missing: $Path"
        }
        Assert-RegularFile -Entry $entry
        if ((Get-FileSha256 -Path $Path) -ne $ExpectedHash) {
            throw "File changed since the installer inspected it: $Path"
        }
    }
    elseif ($null -ne $entry) {
        throw "An entry already exists at the destination: $Path"
    }
}

function Copy-FileVerified {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$DestinationRoot,
        [Parameter(Mandatory)][string]$ExpectedSourceHash,
        [string]$ExpectedDestinationHash
    )

    $safeDestination = Assert-PathWithinRoot -Path $Destination -Root $DestinationRoot
    $temporary = Join-Path $DestinationRoot ('.image-compressor-install-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::Copy($Source, $temporary, $false)
        if ((Get-FileSha256 -Path $temporary) -ne $ExpectedSourceHash) {
            throw "Copy verification failed: $safeDestination"
        }
        if ($ExpectedDestinationHash) {
            Assert-FileState -Path $safeDestination -ExpectedHash $ExpectedDestinationHash
            [IO.File]::Replace($temporary, $safeDestination, [NullString]::Value)
        }
        else {
            [IO.File]::Move($temporary, $safeDestination)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            try { [IO.File]::Delete($temporary) }
            catch { Write-Warning "Installer temporary file could not be removed: $temporary" }
        }
    }
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [switch]$Replace
    )

    $safePath = Assert-PathWithinRoot -Path $Path -Root $Root
    $temporary = Join-Path $Root ('.image-compressor-manifest-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 8))
        $null = Get-Content -LiteralPath $temporary -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($Replace) {
            for ($attempt = 0; ; $attempt++) {
                try {
                    [IO.File]::Replace($temporary, $safePath, [NullString]::Value)
                    break
                }
                catch {
                    $failure = $_.Exception.GetBaseException()
                    $errorCode = $failure.HResult -band 0xffff
                    if ($attempt -ge 4 -or $errorCode -notin 32, 33, 1175 -or
                        -not [IO.File]::Exists($temporary) -or -not [IO.File]::Exists($safePath)) {
                        throw
                    }
                    Start-Sleep -Milliseconds 50
                }
            }
        }
        else {
            [IO.File]::Move($temporary, $safePath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            try { [IO.File]::Delete($temporary) }
            catch { Write-Warning "Installer temporary file could not be removed: $temporary" }
        }
    }
}

function Get-ManagedFileNames {
    param([Parameter(Mandatory)][object[]]$Files)

    $seen = @{}
    foreach ($file in $Files) {
        $name = Assert-SafeFileName -Name ([string]$file.name)
        if ($name -in $settingsName, $markerName -or $seen.ContainsKey($name) -or
            [string]$file.sha256 -notmatch '^[A-Fa-f0-9]{64}$') {
            throw "Invalid managed file entry: $name"
        }
        $seen[$name] = $true
        $name
    }
    if (-not $seen.ContainsKey($executableName)) {
        throw 'Managed file list does not include the executable.'
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
    $marker = Get-ExistingEntry -Path $MarkerPath
    if ($null -ne $marker) {
        Assert-RegularFile -Entry $marker
        $state = Get-Content -LiteralPath $MarkerPath -Raw | ConvertFrom-Json
        if ($state.productId -ne $productId -or $state.schemaVersion -ne 1) {
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
            $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.Name -notin $legacyAllowed
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

function New-InstallOperation {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Kind,
        [string]$Source,
        [string]$AfterHash
    )

    $target = Assert-PathWithinRoot -Path (Join-Path $installDirectory $Name) -Root $installDirectory
    $entry = Get-ExistingEntry -Path $target
    $before = ''
    $backup = ''
    if ($null -ne $entry) {
        if ($Kind -in 'Create', 'CreateSettings', 'CreateMarker') {
            throw "Unmanaged destination entry would collide with the payload: $target"
        }
        Assert-RegularFile -Entry $entry
        $before = Get-FileSha256 -Path $target
        $backup = Join-Path $backupGeneration $Name
    }
    elseif ($Kind -in 'Replace', 'ReplaceMarker') {
        $Kind = 'Create'
    }

    return [pscustomobject][ordered]@{
        path = $target
        kind = $Kind
        source = $Source
        beforeHash = $before
        backup = $backup
        afterHash = $AfterHash
        status = 'Pending'
    }
}

function Restore-InstallOperations {
    param([Parameter(Mandatory)]$Transaction)

    for ($index = $Transaction.operations.Count - 1; $index -ge 0; $index--) {
        $op = $Transaction.operations[$index]
        try {
            if ($op.status -eq 'Started') {
                if ($op.beforeHash) {
                    Assert-FileState -Path $op.path -ExpectedHash $op.beforeHash
                }
                elseif ($null -ne (Get-ExistingEntry -Path $op.path)) {
                    throw 'The installer could not confirm ownership of this entry.'
                }
            }
            elseif ($op.status -eq 'Applied') {
                Assert-FileState -Path $op.path -ExpectedHash $op.afterHash
                if ($op.beforeHash) {
                    Copy-FileVerified -Source $op.backup -Destination $op.path -DestinationRoot $installDirectory `
                        -ExpectedSourceHash $op.beforeHash -ExpectedDestinationHash $op.afterHash
                }
                else {
                    [IO.File]::Delete($op.path)
                }
                Assert-FileState -Path $op.path -ExpectedHash $op.beforeHash
                $op.status = 'Restored'
            }
        }
        catch {
            Write-Output "$($op.path): $($_.Exception.Message)"
        }
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
$operationId = [guid]::NewGuid().ToString('N')
$backupGeneration = Join-Path $backupDirectory "generation-$operationId"
$journalPath = Join-Path $installerStateRoot "transaction-$installHash.json"
$backupPointer = Join-Path $backupDirectory 'latest.json'
$transaction = $null
$transactionStarted = $false
$backupPrepared = $false

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

    $previous = Get-ExistingEntry -Path $journalPath
    if ($null -ne $previous) {
        Assert-RegularFile -Entry $previous
        $record = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($record.state -notin 'Committed', 'RolledBack') {
            $remaining = @($record.operations | Where-Object { $_.status -in 'Started', 'Applied' } |
                ForEach-Object { $_.path })
            throw "An unfinished install is recorded at $journalPath. Backup: $($record.backupGeneration). Review: $($remaining -join ', ')"
        }
    }

    $newManagedNames = @(Get-ManagedFileNames -Files @($payload.managedFiles))
    $initialMarker = Get-ExistingEntry -Path $markerPath
    $markerHash = ''
    if ($null -ne $initialMarker) {
        Assert-RegularFile -Entry $initialMarker
        $markerHash = Get-FileSha256 -Path $markerPath
    }
    $currentState = Get-CurrentInstallState `
        -InstallDirectory $installDirectory `
        -MarkerPath $markerPath
    Assert-FileState -Path $markerPath -ExpectedHash $markerHash
    $oldNames = @()
    if ($null -ne $currentState) {
        $oldNames = @(Get-ManagedFileNames -Files @($currentState.managedFiles))
    }
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
    $stagedMarker = Join-Path $stagingDirectory $markerName
    Write-JsonAtomic -Value $installedManifest -Path $stagedMarker -Root $stagingDirectory

    $operations = [Collections.Generic.List[object]]::new()
    $existingSettings = Get-ExistingEntry -Path $settingsPath
    if ($null -eq $existingSettings) {
        $operations.Add((New-InstallOperation -Name $settingsName -Kind CreateSettings -Source $stagedSettings `
                -AfterHash (Get-FileSha256 -Path $stagedSettings)))
    }
    else {
        Assert-RegularFile -Entry $existingSettings
    }
    foreach ($entry in @($payload.managedFiles)) {
        $name = [string]$entry.name
        $kind = if ($name -in $oldNames) { 'Replace' } else { 'Create' }
        $operations.Add((New-InstallOperation -Name $name -Kind $kind `
                -Source (Join-Path $stagingDirectory $name) -AfterHash ([string]$entry.sha256)))
    }
    foreach ($name in $oldNames | Where-Object { $_ -notin $newManagedNames }) {
        $operation = New-InstallOperation -Name $name -Kind Remove
        if ($operation.beforeHash) {
            $operations.Add($operation)
        }
    }
    Assert-FileState -Path $markerPath -ExpectedHash $markerHash
    $markerKind = if ($markerHash) { 'ReplaceMarker' } else { 'CreateMarker' }
    $operations.Add((New-InstallOperation -Name $markerName -Kind $markerKind -Source $stagedMarker `
            -AfterHash (Get-FileSha256 -Path $stagedMarker)))

    $existingOperations = @($operations | Where-Object beforeHash)
    if ($existingOperations.Count -gt 0) {
        New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
        New-Item -ItemType Directory -Path $backupGeneration | Out-Null
        foreach ($op in $existingOperations) {
            Copy-FileVerified -Source $op.path -Destination $op.backup -DestinationRoot $backupGeneration `
                -ExpectedSourceHash $op.beforeHash
        }
        $backupPrepared = $true
    }

    New-Item -ItemType Directory -Path $installerStateRoot -Force | Out-Null
    $transaction = [ordered]@{
        schemaVersion = 1
        id = $operationId
        installDirectory = $installDirectory
        backupGeneration = $backupGeneration
        state = 'Applying'
        operations = $operations.ToArray()
    }
    Write-JsonAtomic -Value $transaction -Path $journalPath -Root $installerStateRoot -Replace:($null -ne $previous)
    $transactionStarted = $true
    if ($backupPrepared) {
        Write-JsonAtomic -Value @{ generation = $backupGeneration; transaction = $operationId } `
            -Path $backupPointer -Root $backupDirectory -Replace:([IO.File]::Exists($backupPointer))
    }

    if (-not (Test-Path -LiteralPath $installDirectory)) {
        New-Item -ItemType Directory -Path $installDirectory | Out-Null
    }
    $copied = 0
    foreach ($op in $operations) {
        $op.status = 'Started'
        Write-JsonAtomic -Value $transaction -Path $journalPath -Root $installerStateRoot -Replace
        if ($null -ne $TestBeforeOperation) {
            & $TestBeforeOperation $op.path $op.kind
        }

        if ($op.kind -eq 'Remove') {
            Assert-FileState -Path $op.path -ExpectedHash $op.beforeHash
            [IO.File]::Delete($op.path)
        }
        else {
            try {
                Copy-FileVerified -Source $op.source -Destination $op.path -DestinationRoot $installDirectory `
                    -ExpectedSourceHash $op.afterHash -ExpectedDestinationHash $op.beforeHash
            }
            catch {
                if (-not $op.beforeHash) {
                    # Create-new uses an atomic move. An unsuccessful move never owns the destination.
                    $op.status = 'NotApplied'
                }
                throw
            }
        }

        $op.status = 'Applied'
        Write-JsonAtomic -Value $transaction -Path $journalPath -Root $installerStateRoot -Replace
        if ($op.kind -in 'Create', 'Replace') {
            $copied++
            if ($TestFailAfterManagedFileCount -gt 0 -and $copied -ge $TestFailAfterManagedFileCount) {
                throw "Test-only simulated update failure after $copied managed file(s)."
            }
        }
    }

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

    $transaction.state = 'Committed'
    Write-JsonAtomic -Value $transaction -Path $journalPath -Root $installerStateRoot -Replace
    $transactionStarted = $false
    Write-Host "Image Compressor $Runtime was installed or updated successfully." -ForegroundColor Green
    Write-Host "Install folder: $installDirectory" -ForegroundColor Green
    Write-Host "Executable: $installedExe" -ForegroundColor Green
    Write-Host 'The application was not started automatically.' -ForegroundColor Cyan
    if ($backupPrepared) {
        Write-Host "Verified pre-update files are retained at: $backupGeneration" -ForegroundColor Yellow
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
    if ($transactionStarted) {
        try {
            $remaining = @(Restore-InstallOperations -Transaction $transaction)
            if ($remaining.Count -eq 0) {
                $transaction.state = 'RolledBack'
                Write-JsonAtomic -Value $transaction -Path $journalPath -Root $installerStateRoot -Replace
                Write-Host 'The changes made by this installation were restored.' -ForegroundColor Yellow
            }
            else {
                $transaction.state = 'RollbackIncomplete'
                $transaction.unrestored = $remaining
                Write-JsonAtomic -Value $transaction -Path $journalPath -Root $installerStateRoot -Replace
                Write-Warning "Automatic rollback incomplete. Record: $journalPath. Backup: $backupGeneration."
                $remaining | ForEach-Object { Write-Warning $_ }
            }
        }
        catch {
            Write-Warning "Automatic rollback could not finish: $($_.Exception.Message). Record: $journalPath. Backup: $backupGeneration."
        }
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
