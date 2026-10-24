Describe 'Image Compressor one-click installer' -Tag 'WindowsOnly' {
    BeforeAll {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $script:projectRoot = [IO.Path]::GetFullPath(
            (Join-Path $PSScriptRoot '..\..\..'))
        $script:facadeEntryBatch = Join-Path (
            Split-Path -Parent $script:projectRoot
        ) 'ここから開始 - Image Compressorを導入・更新.bat'
        $script:distributionRoot = if (-not [string]::IsNullOrWhiteSpace(
                $env:IMAGE_COMPRESSOR_TEST_DISTRIBUTION_ROOT)) {
            [IO.Path]::GetFullPath($env:IMAGE_COMPRESSOR_TEST_DISTRIBUTION_ROOT)
        }
        else {
            Join-Path $script:projectRoot 'dist\image-compressor-installer'
        }
        $script:installer = Join-Path $script:distributionRoot 'installer\Install-ImageCompressor.ps1'
        $script:entryBatch = Join-Path $script:distributionRoot 'ここから開始 - Image Compressorを導入・更新.bat'
        $script:payloadRoot = Join-Path $script:distributionRoot 'installer\payload'
        $script:payloadManifest = Get-Content `
            -LiteralPath (Join-Path $script:payloadRoot 'payload-manifest.json') `
            -Raw |
            ConvertFrom-Json
        $script:parent = Join-Path $TestDrive '導入先 空白 & ^ % !'
        $script:stateRoot = Join-Path $TestDrive 'installer-state'
        $script:installDirectory = Join-Path $script:parent 'Image Compressor'
        $script:installedExe = Join-Path $script:installDirectory 'ImageCompressor.App.exe'
        New-Item -ItemType Directory -Path $script:parent | Out-Null
        New-Item -ItemType Directory -Path $script:stateRoot | Out-Null

        function Invoke-TestInstaller {
            param(
                [string]$Runtime = 'win-x64',
                [string]$OutputRoot = $script:parent,
                [string]$InstallerPath = $script:installer,
                [string]$InstallerStateRoot = $script:stateRoot,
                [string[]]$ExtraArguments = @()
            )

            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = if ($env:IMAGE_COMPRESSOR_TEST_POWERSHELL_EXE) {
                $env:IMAGE_COMPRESSOR_TEST_POWERSHELL_EXE
            }
            else { 'powershell.exe' }
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            foreach ($argument in @(
                    '-NoLogo',
                    '-NoProfile',
                    '-File',
                    $InstallerPath,
                    '-Runtime',
                    $Runtime,
                    '-OutputRoot',
                    $OutputRoot,
                    '-InstallerStateRoot',
                    $InstallerStateRoot
                ) + $ExtraArguments) {
                $startInfo.ArgumentList.Add($argument)
            }
            $process = [Diagnostics.Process]::Start($startInfo)
            $standardOutput = $process.StandardOutput.ReadToEndAsync()
            $standardError = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit(120000) | Should -BeTrue
            return [pscustomobject]@{
                ExitCode = $process.ExitCode
                Output = $standardOutput.Result
                Error = $standardError.Result
            }
        }

        function Get-TestPeMachine {
            param([Parameter(Mandatory)][string]$Path)

            $stream = [IO.File]::OpenRead($Path)
            try {
                $reader = [IO.BinaryReader]::new($stream)
                $stream.Position = 0x3c
                $peOffset = $reader.ReadInt32()
                $stream.Position = $peOffset
                $reader.ReadUInt32() | Should -Be 0x00004550
                return $reader.ReadUInt16()
            }
            finally {
                $stream.Dispose()
            }
        }

        function Test-BinaryContainsUtf8Text {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][string]$Text
            )

            $carry = ''
            $buffer = [byte[]]::new(4MB)
            $stream = [IO.File]::OpenRead($Path)
            try {
                while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $chunk = $carry + [Text.Encoding]::UTF8.GetString($buffer, 0, $read)
                    if ($chunk.Contains($Text, [StringComparison]::OrdinalIgnoreCase)) {
                        return $true
                    }
                    $carryLength = [Math]::Min(
                        [Math]::Max($Text.Length - 1, 0),
                        $chunk.Length)
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

        function Get-TestStableHash {
            param([Parameter(Mandatory)][string]$Value)

            $hash = [Security.Cryptography.SHA256]::HashData(
                [Text.Encoding]::UTF8.GetBytes($Value))
            return [Convert]::ToHexString($hash)
        }

        function Wait-TestExecutableUnlocked {
            param([Parameter(Mandatory)][string]$Path)

            $stableSamples = 0
            for ($attempt = 0; $attempt -lt 50; $attempt++) {
                $stream = $null
                try {
                    $stream = [IO.File]::Open(
                        $Path,
                        [IO.FileMode]::Open,
                        [IO.FileAccess]::ReadWrite,
                        [IO.FileShare]::None)
                    $stableSamples++
                    if ($stableSamples -ge 15) { return }
                }
                catch [IO.IOException] {
                    $stableSamples = 0
                }
                finally {
                    if ($null -ne $stream) {
                        $stream.Dispose()
                    }
                }
                Start-Sleep -Milliseconds 100
            }
            throw "Executable remained locked after process exit: $Path"
        }
    }

    It '実cmd入口が特殊文字pathとauto判定要求をinstallerへ渡す' {
        $probe = Join-Path $TestDrive 'installer-probe.cmd'
        $probeOutput = Join-Path $TestDrive 'installer-probe.txt'
        @'
@echo off
> "%IMAGE_COMPRESSOR_INSTALLER_PROBE_OUTPUT%" echo RUNTIME=[%~1]
>> "%IMAGE_COMPRESSOR_INSTALLER_PROBE_OUTPUT%" set IMAGE_COMPRESSOR_INSTALL_ROOT
'@ | Set-Content -LiteralPath $probe -Encoding ascii

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $script:entryBatch
        $startInfo.UseShellExecute = $true
        $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $startInfo.ArgumentList.Add($script:parent)
        $savedProbe = $env:IMAGE_COMPRESSOR_INSTALLER_TEST_PROBE
        $savedOutput = $env:IMAGE_COMPRESSOR_INSTALLER_PROBE_OUTPUT
        $savedArchitecture = $env:PROCESSOR_ARCHITECTURE
        $savedWowArchitecture = $env:PROCESSOR_ARCHITEW6432
        try {
            $env:IMAGE_COMPRESSOR_INSTALLER_TEST_PROBE = $probe
            $env:IMAGE_COMPRESSOR_INSTALLER_PROBE_OUTPUT = $probeOutput
            $env:PROCESSOR_ARCHITECTURE = 'AMD64'
            Remove-Item Env:PROCESSOR_ARCHITEW6432 -ErrorAction SilentlyContinue
            $process = [Diagnostics.Process]::Start($startInfo)
            $process.WaitForExit()
        }
        finally {
            $env:IMAGE_COMPRESSOR_INSTALLER_TEST_PROBE = $savedProbe
            $env:IMAGE_COMPRESSOR_INSTALLER_PROBE_OUTPUT = $savedOutput
            $env:PROCESSOR_ARCHITECTURE = $savedArchitecture
            $env:PROCESSOR_ARCHITEW6432 = $savedWowArchitecture
        }

        $process.ExitCode | Should -Be 0
        $lines = @(Get-Content -LiteralPath $probeOutput -Encoding oem)
        $lines[0] | Should -Be 'RUNTIME=[auto]'
        $lines[1] | Should -Be "IMAGE_COMPRESSOR_INSTALL_ROOT=$($script:parent)"
    }

    It 'workspace直下の入口がproject内installerを検出しauto判定を渡す' {
        $facadeRoot = Join-Path $TestDrive 'source-layout-facade'
        $fixtureInstaller = Join-Path $facadeRoot 'project\installer'
        $fixturePayload = Join-Path $fixtureInstaller 'payload'
        New-Item -ItemType Directory -Path $fixturePayload -Force | Out-Null
        $fixtureEntry = Join-Path $facadeRoot 'ここから開始 - Image Compressorを導入・更新.bat'
        Copy-Item -LiteralPath $script:facadeEntryBatch -Destination $fixtureEntry
        Copy-Item -LiteralPath $script:installer -Destination $fixtureInstaller
        Copy-Item -LiteralPath (Join-Path $script:payloadRoot 'payload-manifest.json') -Destination $fixturePayload
        $probe = Join-Path $TestDrive 'facade-installer-probe.cmd'
        $probeOutput = Join-Path $TestDrive 'facade-installer-probe.txt'
        @'
@echo off
> "%IMAGE_COMPRESSOR_INSTALLER_PROBE_OUTPUT%" echo RUNTIME=[%~1]
'@ | Set-Content -LiteralPath $probe -Encoding ascii

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = 'cmd.exe'
        $startInfo.UseShellExecute = $false
        $startInfo.ArgumentList.Add('/d')
        $startInfo.ArgumentList.Add('/c')
        $startInfo.ArgumentList.Add('call')
        $startInfo.ArgumentList.Add($fixtureEntry)
        $startInfo.Environment['IMAGE_COMPRESSOR_INSTALLER_TEST_PROBE'] = $probe
        $startInfo.Environment['IMAGE_COMPRESSOR_INSTALLER_PROBE_OUTPUT'] = $probeOutput
        $startInfo.Environment['PROCESSOR_ARCHITECTURE'] = 'AMD64'
        $startInfo.Environment.Remove('PROCESSOR_ARCHITEW6432') | Out-Null
        $process = [Diagnostics.Process]::Start($startInfo)
        $process.WaitForExit()

        $process.ExitCode | Should -Be 0
        (Get-Content -LiteralPath $probeOutput -Raw).Trim() |
            Should -Be 'RUNTIME=[auto]'
    }

    It 'source-only入口はpayload不在を拒否しsourceを変更しない' {
        $sourcePayload = Join-Path $script:projectRoot 'installer\payload'
        Test-Path -LiteralPath $sourcePayload | Should -BeFalse
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = 'cmd.exe'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        foreach ($arg in @('/d', '/c', 'call', $script:facadeEntryBatch)) {
            $startInfo.ArgumentList.Add($arg)
        }
        $process = [Diagnostics.Process]::Start($startInfo)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.WriteLine(' ')
        $process.StandardInput.Close()
        $process.WaitForExit(10000) | Should -BeTrue
        $process.ExitCode | Should -Be 1
        $stderr.Result | Should -BeNullOrEmpty
        $stdout.Result | Should -Match 'Source checkouts do not include prebuilt payloads'
        Test-Path -LiteralPath $sourcePayload | Should -BeFalse
        $process.Dispose()
    }
    It 'entry BATは親のARM64環境でもOS native判定をinstallerへ委譲する' {
        $probe = Join-Path $TestDrive 'installer-probe-arm64.cmd'
        $probeOutput = Join-Path $TestDrive 'installer-probe-arm64.txt'
        @'
@echo off
> "%IMAGE_COMPRESSOR_INSTALLER_PROBE_OUTPUT%" echo RUNTIME=[%~1]
'@ | Set-Content -LiteralPath $probe -Encoding ascii
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = 'cmd.exe'
        $startInfo.UseShellExecute = $false
        $startInfo.ArgumentList.Add('/d')
        $startInfo.ArgumentList.Add('/c')
        $startInfo.ArgumentList.Add('call')
        $startInfo.ArgumentList.Add($script:entryBatch)
        $startInfo.Environment['IMAGE_COMPRESSOR_INSTALLER_TEST_PROBE'] = $probe
        $startInfo.Environment['IMAGE_COMPRESSOR_INSTALLER_PROBE_OUTPUT'] = $probeOutput
        $startInfo.Environment['PROCESSOR_ARCHITECTURE'] = 'ARM64'
        $startInfo.Environment.Remove('PROCESSOR_ARCHITEW6432') | Out-Null
        $process = [Diagnostics.Process]::Start($startInfo)
        $process.WaitForExit()

        $process.ExitCode | Should -Be 0
        (Get-Content -LiteralPath $probeOutput -Raw).Trim() |
            Should -Be 'RUNTIME=[auto]'
    }

    It 'autoのread-only判定はpayloadや導入先がなくてもstateを生成しない' {
        $missing = Join-Path $TestDrive 'runtime-detect-no-input'
        $result = Invoke-TestInstaller -Runtime auto -OutputRoot $missing `
            -InstallerStateRoot (Join-Path $missing 'state') `
            -ExtraArguments @('-DetectRuntimeOnly', '-PackageRoot', $missing)

        $result.ExitCode | Should -Be 0
        $result.Output.Trim() | Should -Be 'win-x64'
        Test-Path -LiteralPath $missing | Should -BeFalse
    }

    It 'auto判定で同じPCのnative x64版を隔離導入する' {
        $parent = Join-Path $TestDrive 'auto-native-install'
        New-Item -ItemType Directory -Path $parent | Out-Null
        $result = Invoke-TestInstaller -Runtime auto -OutputRoot $parent
        $result.ExitCode | Should -Be 0
        $marker = Get-Content -LiteralPath (
            Join-Path $parent 'Image Compressor/.image-compressor-install.json'
        ) -Raw | ConvertFrom-Json
        $marker.runtime | Should -Be 'win-x64'
    }

    It 'x64とARM64 payloadのSHA-256とPE machineがmanifestに一致する' {
        $script:payloadManifest.productVersion | Should -Match '^\d+\.\d+\.\d+$'
        $script:payloadManifest.buildId | Should -Match '^sha256\.[0-9a-f]{16}$'
        $script:payloadManifest.sourceDigest | Should -Match '^[0-9A-F]{64}$'
        foreach ($runtime in 'win-x64', 'win-arm64') {
            $payload = $script:payloadManifest.payloads.PSObject.Properties[$runtime].Value
            @($payload.managedFiles.name) | Should -Contain 'LICENSE'
            $licenseSource = Join-Path (Split-Path -Parent $script:projectRoot) 'LICENSE'
            $archive = Join-Path $script:payloadRoot $payload.archive
            (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash |
                Should -Be $payload.sha256
            $extract = Join-Path $TestDrive "payload-$runtime"
            [IO.Compression.ZipFile]::ExtractToDirectory($archive, $extract)
            (Get-FileHash -LiteralPath (Join-Path $extract 'LICENSE') -Algorithm SHA256).Hash |
                Should -Be (Get-FileHash -LiteralPath $licenseSource -Algorithm SHA256).Hash
            (Get-FileHash -LiteralPath (Join-Path $script:distributionRoot 'LICENSE') -Algorithm SHA256).Hash |
                Should -Be (Get-FileHash -LiteralPath $licenseSource -Algorithm SHA256).Hash
            foreach ($legalName in @(
                    'DOTNET-LIBRARY-LICENSE.html',
                    'DOTNET-LICENSE.txt',
                    'DOTNET-THIRD-PARTY-NOTICES.txt',
                    'WINDOWSDESKTOP-LICENSE.txt')) {
                @($payload.managedFiles.name) | Should -Contain $legalName
                (Get-FileHash -LiteralPath (Join-Path $extract $legalName) -Algorithm SHA256).Hash |
                    Should -Be (Get-FileHash -LiteralPath (Join-Path $script:projectRoot "installer/assets/legal/$legalName") -Algorithm SHA256).Hash
            }
            $machine = Get-TestPeMachine -Path (Join-Path $extract 'ImageCompressor.App.exe')
            [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $extract 'ImageCompressor.App.exe')).ProductVersion |
                Should -BeExactly ($script:payloadManifest.productVersion + '+' + $script:payloadManifest.buildId)
            $machine | Should -Be ([int]$payload.peMachine)
            $machine | Should -Be $(if ($runtime -eq 'win-arm64') { 0xAA64 } else { 0x8664 })
            $workspaceRoot = [IO.Path]::GetFullPath((Join-Path $script:projectRoot '..\..'))
            Test-BinaryContainsUtf8Text `
                -Path (Join-Path $extract 'ImageCompressor.App.exe') `
                -Text $workspaceRoot |
                Should -BeFalse
            foreach ($entry in @($payload.managedFiles) + @($payload.userOwnedSeedFiles)) {
                $file = Join-Path $extract ([string]$entry.name)
                Test-Path -LiteralPath $file -PathType Leaf | Should -BeTrue
                (Get-Item -LiteralPath $file).Length | Should -Be ([long]$entry.bytes)
                (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash |
                    Should -Be ([string]$entry.sha256)
            }
            @($payload.userOwnedSeedFiles).Count | Should -Be 1
            $payload.userOwnedSeedFiles[0].name | Should -Be 'settings.json'
        }
    }

    It '特殊文字を含む空の親folderへ専用folderだけを新規導入する' {
        $result = Invoke-TestInstaller

        $result.ExitCode | Should -Be 0 -Because ($result.Output + $result.Error)
        $names = @(Get-ChildItem -LiteralPath $script:installDirectory -Force |
            Select-Object -ExpandProperty Name |
            Sort-Object)
        $expectedNames = @(
            '.image-compressor-install.json',
            'settings.json'
        ) + @($script:payloadManifest.payloads.'win-x64'.managedFiles.name)
        $names | Should -Be @($expectedNames | Sort-Object)
        Get-TestPeMachine -Path $script:installedExe | Should -Be 0x8664
        $marker = Get-Content `
            -LiteralPath (Join-Path $script:installDirectory '.image-compressor-install.json') `
            -Raw |
            ConvertFrom-Json
        $marker.runtime | Should -Be 'win-x64'
    }

    It 'drive rootを親folderに指定して専用folderへ導入できる' {
        $mappedDirectory = Join-Path $TestDrive 'drive-root-parent'
        New-Item -ItemType Directory -Path $mappedDirectory | Out-Null
        $usedRoots = @([IO.DriveInfo]::GetDrives().Name)
        $driveName = $null
        foreach ($codePoint in 90..68) {
            $candidate = '{0}:' -f [char]$codePoint
            if (($candidate + '\') -notin $usedRoots) {
                $driveName = $candidate
                break
            }
        }
        $driveName | Should -Not -BeNullOrEmpty
        $driveRoot = $driveName + '\'

        try {
            & subst.exe $driveName $mappedDirectory
            $LASTEXITCODE | Should -Be 0

            $result = Invoke-TestInstaller -OutputRoot $driveRoot

            $result.ExitCode | Should -Be 0 -Because ($result.Output + $result.Error)
            Test-Path -LiteralPath (
                Join-Path $driveRoot 'Image Compressor\ImageCompressor.App.exe') |
                Should -BeTrue
        }
        finally {
            & subst.exe $driveName /d | Out-Null
        }
    }

    It 'インストール後の自己完結EXEが起動し、起動中updateを拒否する' {
        $before = (Get-FileHash -LiteralPath $script:installedExe -Algorithm SHA256).Hash
        $process = Start-Process `
            -FilePath $script:installedExe `
            -ArgumentList 'min' `
            -WindowStyle Hidden `
            -PassThru
        try {
            Start-Sleep -Milliseconds 800
            $process.HasExited | Should -BeFalse
            $result = Invoke-TestInstaller
            $result.ExitCode | Should -Not -Be 0
            ($result.Output + $result.Error) | Should -Match 'is running from the update target'
            (Get-FileHash -LiteralPath $script:installedExe -Algorithm SHA256).Hash |
                Should -Be $before
        }
        finally {
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id -Force
                $process.WaitForExit()
            }
            $process.Dispose()
            Wait-TestExecutableUnlocked -Path $script:installedExe
        }
    }

    It 'updateがsettingsと利用者追加fileを保持しmanaged backupを1世代作る' {
        $settingsPath = Join-Path $script:installDirectory 'settings.json'
        $userFile = Join-Path $script:installDirectory '利用者メモ & % !.txt'
        $settingsSentinel = '{"schemaVersion":1,"sentinel":"USER-SETTINGS-&-%-!"}'
        Set-Content -LiteralPath $settingsPath -Value $settingsSentinel -Encoding utf8
        Set-Content -LiteralPath $userFile -Value 'USER-FILE-SENTINEL' -Encoding utf8

        $result = Invoke-TestInstaller

        $result.ExitCode | Should -Be 0 -Because ($result.Output + $result.Error)
        (Get-Content -LiteralPath $settingsPath -Raw).Trim() |
            Should -Be $settingsSentinel
        (Get-Content -LiteralPath $userFile -Raw).Trim() |
            Should -Be 'USER-FILE-SENTINEL'
        $backup = Get-ChildItem -LiteralPath (Join-Path $script:stateRoot 'Backups') -Directory
        $backup.Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $backup.FullName 'settings.json') |
            Should -BeFalse
    }

    It '反映途中の意図的failureから前世代へ自動rollbackする' {
        $readme = Join-Path $script:installDirectory 'README.md'
        Set-Content -LiteralPath $readme -Value 'ROLLBACK-SENTINEL' -Encoding utf8
        $beforeExe = (Get-FileHash -LiteralPath $script:installedExe -Algorithm SHA256).Hash
        $beforeMarker = (Get-FileHash `
                -LiteralPath (Join-Path $script:installDirectory '.image-compressor-install.json') `
                -Algorithm SHA256).Hash

        $result = Invoke-TestInstaller -ExtraArguments @(
            '-TestFailAfterManagedFileCount',
            '2'
        )

        $result.ExitCode | Should -Not -Be 0
        ($result.Output + $result.Error) | Should -Match 'previous managed installation was restored'
        (Get-Content -LiteralPath $readme -Raw).Trim() |
            Should -Be 'ROLLBACK-SENTINEL'
        (Get-FileHash -LiteralPath $script:installedExe -Algorithm SHA256).Hash |
            Should -Be $beforeExe
        (Get-FileHash `
            -LiteralPath (Join-Path $script:installDirectory '.image-compressor-install.json') `
            -Algorithm SHA256).Hash |
            Should -Be $beforeMarker
    }

    It '同じinstall先の更新mutexを取得できない場合は何も変更しない' {
        $installHash = (Get-TestStableHash `
                -Value $script:installDirectory.ToUpperInvariant()).Substring(0, 16)
        $mutex = [Threading.Mutex]::new(
            $false,
            "Local\ImageCompressor-Installer-$installHash")
        $taken = $mutex.WaitOne(0)
        $taken | Should -BeTrue
        try {
            $before = (Get-FileHash -LiteralPath $script:installedExe -Algorithm SHA256).Hash
            $result = Invoke-TestInstaller
            $result.ExitCode | Should -Not -Be 0
            ($result.Output + $result.Error) | Should -Match 'Another Image Compressor installation/update'
            (Get-FileHash -LiteralPath $script:installedExe -Algorithm SHA256).Hash |
                Should -Be $before
        }
        finally {
            if ($taken) {
                $mutex.ReleaseMutex()
            }
            $mutex.Dispose()
        }
    }

    It 'ARM64指定ではARM64専用folderへ正しいpayloadだけを配置する' {
        $armParent = Join-Path $TestDrive 'arm64-parent'
        New-Item -ItemType Directory -Path $armParent | Out-Null

        $result = Invoke-TestInstaller -Runtime 'win-arm64' -OutputRoot $armParent

        $result.ExitCode | Should -Be 0 -Because ($result.Output + $result.Error)
        $armInstall = Join-Path $armParent 'Image Compressor'
        Get-TestPeMachine -Path (Join-Path $armInstall 'ImageCompressor.App.exe') |
            Should -Be 0xAA64
        $marker = Get-Content `
            -LiteralPath (Join-Path $armInstall '.image-compressor-install.json') `
            -Raw |
            ConvertFrom-Json
        $marker.runtime | Should -Be 'win-arm64'
    }

    It '一般配布folderと導入先に開発用fileが混入しない' {
        $distribution = $script:distributionRoot
        $forbiddenExtensions = @('.cs', '.csproj', '.sln', '.slnx', '.pdb', '.obj', '.log')
        $forbiddenNames = @('src', 'tests', 'bin', 'obj', '.build')
        $distributionItems = @(Get-ChildItem -LiteralPath $distribution -Recurse -Force)
        @($distributionItems | Where-Object {
                $_.Name -in $forbiddenNames -or $_.Extension -in $forbiddenExtensions
            }).Count | Should -Be 0
        @(
            Get-ChildItem -LiteralPath $script:installDirectory -Recurse -Force |
                Where-Object {
                    $_.Name -in $forbiddenNames -or $_.Extension -in $forbiddenExtensions
                }
        ).Count | Should -Be 0
    }

    It '旧version markerからcandidateへsettingsを保持して更新する' {
        $oldPackageRoot = Join-Path $TestDrive 'previous-version-package'
        $oldInstallerRoot = Join-Path $oldPackageRoot 'installer'
        $oldPayloadRoot = Join-Path $oldInstallerRoot 'payload'
        $upgradeParent = Join-Path $TestDrive 'previous-to-candidate-parent'
        $upgradeStateRoot = Join-Path $TestDrive 'previous-to-candidate-state'
        foreach ($directory in $oldPayloadRoot, $upgradeParent, $upgradeStateRoot) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $oldInstaller = Join-Path $oldInstallerRoot 'Install-ImageCompressor.ps1'
        Copy-Item `
            -LiteralPath (Join-Path $script:projectRoot 'installer\Install-ImageCompressor.ps1') `
            -Destination $oldInstaller
        $oldArchiveName = [string]$script:payloadManifest.payloads.'win-x64'.archive
        Copy-Item `
            -LiteralPath (Join-Path $script:payloadRoot $oldArchiveName) `
            -Destination (Join-Path $oldPayloadRoot $oldArchiveName)
        $oldPayloadManifest = $script:payloadManifest |
            ConvertTo-Json -Depth 10 |
            ConvertFrom-Json
        $oldPayloadManifest.productVersion = '0.9.0-test'
        $oldPayloadManifest.payloads.PSObject.Properties.Remove('win-arm64')
        $oldPayloadManifest |
            ConvertTo-Json -Depth 10 |
            Set-Content `
                -LiteralPath (Join-Path $oldPayloadRoot 'payload-manifest.json') `
                -Encoding utf8

        $oldResult = Invoke-TestInstaller `
            -InstallerPath $oldInstaller `
            -OutputRoot $upgradeParent `
            -InstallerStateRoot $upgradeStateRoot
        $oldResult.ExitCode | Should -Be 0 -Because ($oldResult.Output + $oldResult.Error)

        $upgradeInstall = Join-Path $upgradeParent 'Image Compressor'
        $markerPath = Join-Path $upgradeInstall '.image-compressor-install.json'
        $settingsPath = Join-Path $upgradeInstall 'settings.json'
        $oldMarker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        $oldMarker.productVersion | Should -Be '0.9.0-test'
        $settingsSentinel = '{"schemaVersion":1,"sentinel":"PREVIOUS-USER-SETTINGS"}'
        Set-Content -LiteralPath $settingsPath -Value $settingsSentinel -Encoding utf8

        $newResult = Invoke-TestInstaller `
            -OutputRoot $upgradeParent `
            -InstallerStateRoot $upgradeStateRoot
        $newResult.ExitCode | Should -Be 0 -Because ($newResult.Output + $newResult.Error)

        $newMarker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
        $newMarker.productVersion | Should -Be $script:payloadManifest.productVersion
        $newExeHash = (Get-FileHash `
                -LiteralPath (Join-Path $upgradeInstall 'ImageCompressor.App.exe') `
                -Algorithm SHA256).Hash
        $newExeHash | Should -Be $script:payloadManifest.payloads.'win-x64'.executableSha256
        (Get-Content -LiteralPath $settingsPath -Raw).Trim() | Should -Be $settingsSentinel
    }

    It 'READMEどおりの手動uninstallで設定backupを残して隔離導入先だけを削除する' {
        $settingsPath = Join-Path $script:installDirectory 'settings.json'
        $settingsBackup = Join-Path $TestDrive 'settings-backup.json'
        Copy-Item -LiteralPath $settingsPath -Destination $settingsBackup

        $testRoot = [IO.Path]::GetFullPath($TestDrive).TrimEnd('\')
        $installFull = [IO.Path]::GetFullPath($script:installDirectory)
        $stateFull = [IO.Path]::GetFullPath($script:stateRoot)
        foreach ($target in $installFull, $stateFull) {
            $target.StartsWith(
                $testRoot + [IO.Path]::DirectorySeparatorChar,
                [StringComparison]::OrdinalIgnoreCase) | Should -BeTrue
            (Get-Item -LiteralPath $target -Force).Attributes.HasFlag(
                [IO.FileAttributes]::ReparsePoint) | Should -BeFalse
        }

        Remove-Item -LiteralPath $installFull -Recurse -Force
        Remove-Item -LiteralPath $stateFull -Recurse -Force

        Test-Path -LiteralPath $settingsBackup -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath $installFull | Should -BeFalse
        Test-Path -LiteralPath $stateFull | Should -BeFalse
    }
}
