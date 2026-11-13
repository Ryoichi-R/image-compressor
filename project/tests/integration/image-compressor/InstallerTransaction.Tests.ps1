#Requires -Modules Pester

Describe 'Installer transaction with synthetic payload' {
    BeforeAll {
        $script:sourceInstaller = Join-Path $PSScriptRoot '../../../installer/Install-ImageCompressor.ps1'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        function New-SyntheticPackage {
            param([string]$Root)
            $installerRoot = Join-Path $Root 'installer'
            $payloadRoot = Join-Path $installerRoot 'payload'
            $source = Join-Path $Root 'synthetic'
            New-Item -ItemType Directory -Path $payloadRoot, $source -Force | Out-Null
            Copy-Item -LiteralPath $script:sourceInstaller -Destination $installerRoot
            $pe = [byte[]]::new(128)
            $pe[0] = 0x4d
            $pe[1] = 0x5a
            $pe[0x3c] = 64
            $pe[64] = 0x50
            $pe[65] = 0x45
            $pe[68] = 0x64
            $pe[69] = 0x86
            $exe = 'ImageCompressor.App.exe'
            [IO.File]::WriteAllBytes((Join-Path $source $exe), $pe)
            [IO.File]::WriteAllText((Join-Path $source 'notes.txt'), 'new package file')
            [IO.File]::WriteAllText((Join-Path $source 'settings.json'), '{}')
            $archive = Join-Path $payloadRoot 'synthetic.zip'
            [IO.Compression.ZipFile]::CreateFromDirectory($source, $archive)
            $managed = @($exe, 'notes.txt' | ForEach-Object {
                @{ name = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $source $_)).Hash }
            })
            @{
                schemaVersion = 1
                productId = 'image-compressor'
                productVersion = 'synthetic'
                payloads = @{
                    'win-x64' = @{
                        archive = 'synthetic.zip'
                        sha256 = (Get-FileHash -LiteralPath $archive).Hash
                        executableSha256 = $managed[0].sha256
                        peMachine = 0x8664
                        managedFiles = $managed
                    }
                }
            } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $payloadRoot 'payload-manifest.json')
            Join-Path $installerRoot 'Install-ImageCompressor.ps1'
        }
    }

    BeforeEach {
        $case = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $package = Join-Path $case 'package'
        $parent = Join-Path $case 'target'
        $install = Join-Path $parent 'Image Compressor'
        $state = Join-Path $case 'state'
        New-Item -ItemType Directory -Path $install | Out-Null
        $script:installer = New-SyntheticPackage -Root $package
        $script:invoke = @{ Runtime = 'win-x64'; OutputRoot = $parent; PackageRoot = $package; InstallerStateRoot = $state }
        $exe = Join-Path $install 'ImageCompressor.App.exe'
        $script:notes = Join-Path $install 'notes.txt'
        $settings = Join-Path $install 'settings.json'
        $marker = Join-Path $install '.image-compressor-install.json'
        [IO.File]::WriteAllText($exe, 'old synthetic executable bytes')
        [IO.File]::WriteAllText($settings, '{"keep":true}')
        $oldExeHash = (Get-FileHash -LiteralPath $exe).Hash
        @{
            schemaVersion = 1; productId = 'image-compressor'; productVersion = 'old'; installedAt = '2000-01-01'
            managedFiles = @(@{ name = 'ImageCompressor.App.exe'; sha256 = $oldExeHash })
        } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $marker
        $script:oldMarkerHash = (Get-FileHash -LiteralPath $marker).Hash
    }

    It 'rejects a collision before creating a backup or touching user files' {
        [IO.File]::WriteAllText($script:notes, 'user note')
        { & $script:installer @script:invoke } | Should -Throw '*Unmanaged destination entry*'
        [IO.File]::ReadAllText($script:notes) | Should -BeExactly 'user note'
        (Get-FileHash -LiteralPath $exe).Hash | Should -BeExactly $oldExeHash
        (Get-FileHash -LiteralPath $marker).Hash | Should -BeExactly $script:oldMarkerHash
        $state | Should -Not -Exist
    }

    It 'keeps a concurrent create even when its hash matches the payload' {
        $hook = {
            param($path, $kind)
            if ($kind -eq 'Create' -and [IO.Path]::GetFileName($path) -eq 'notes.txt') {
                [IO.File]::WriteAllText($path, 'new package file')
            }
        }
        { & $script:installer @script:invoke -TestBeforeOperation $hook } | Should -Throw
        [IO.File]::ReadAllText($script:notes) | Should -BeExactly 'new package file'
        (Get-FileHash -LiteralPath $exe).Hash | Should -BeExactly $oldExeHash
        (Get-FileHash -LiteralPath $marker).Hash | Should -BeExactly $script:oldMarkerHash
        (Get-Content -Raw -LiteralPath (Get-ChildItem $state -Filter 'transaction-*.json').FullName |
            ConvertFrom-Json).state | Should -Be 'RolledBack'
    }

    It 'restores prior bytes after a completed replacement and permits a later successful update' {
        { & $script:installer @script:invoke -TestFailAfterManagedFileCount 1 } | Should -Throw '*simulated update failure*'
        (Get-FileHash -LiteralPath $exe).Hash | Should -BeExactly $oldExeHash
        $script:notes | Should -Not -Exist
        & $script:installer @script:invoke
        [IO.File]::ReadAllText($script:notes) | Should -BeExactly 'new package file'
        [IO.File]::ReadAllText($settings) | Should -BeExactly '{"keep":true}'
    }

    It 'blocks retries when rollback could not restore a concurrently modified target' {
        $hook = {
            param($path, $kind)
            if ($kind -eq 'Create' -and [IO.Path]::GetFileName($path) -eq 'notes.txt') {
                [IO.File]::WriteAllText((Join-Path ([IO.Path]::GetDirectoryName($path)) 'ImageCompressor.App.exe'), 'changed externally')
                throw 'injected failure'
            }
        }
        { & $script:installer @script:invoke -TestBeforeOperation $hook } | Should -Throw '*injected failure*'
        $backup = Get-ChildItem -LiteralPath $state -Recurse -Filter 'ImageCompressor.App.exe'
        $backup.Count | Should -Be 1
        (Get-FileHash -LiteralPath $backup.FullName).Hash | Should -BeExactly $oldExeHash
        { & $script:installer @script:invoke } | Should -Throw '*unfinished install*'
        [IO.File]::ReadAllText($exe) | Should -BeExactly 'changed externally'
        (Get-FileHash -LiteralPath $backup.FullName).Hash | Should -BeExactly $oldExeHash
    }

    It 'updates an identified markerless installation and preserves portable settings' {
        Remove-Item -LiteralPath $marker
        & $script:installer @script:invoke
        $marker | Should -Exist
        [IO.File]::ReadAllText($settings) | Should -BeExactly '{"keep":true}'
        [IO.File]::ReadAllText($script:notes) | Should -BeExactly 'new package file'
    }
}
