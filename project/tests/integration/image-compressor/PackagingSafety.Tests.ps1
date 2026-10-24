Describe 'Image Compressor candidate packaging safety' -Tag 'WindowsOnly' {
    BeforeAll {
        $script:projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
        . (Join-Path $script:projectRoot 'scripts/_secret-path-guard.ps1')
        $script:payloadRoot = Join-Path $script:projectRoot 'installer\payload'
        $script:builder = Join-Path $script:projectRoot 'scripts\build-image-compressor-installer-package.ps1'
        $script:candidateBuilder = Join-Path $script:projectRoot 'scripts\new-image-compressor-candidate-package.ps1'
        $script:backupScript = Join-Path $script:projectRoot 'scripts\backup-image-compressor-payload.ps1'
        function Get-PayloadSnapshot {
            if (-not (Test-Path -LiteralPath $script:payloadRoot -PathType Container)) {
                return @()
            }
            return @(
                Get-ChildItem -LiteralPath $script:payloadRoot -File |
                    Sort-Object Name |
                    ForEach-Object {
                        '{0}|{1}|{2}' -f @(
                            $_.Name,
                            $_.Length,
                            (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)
                    }
            )
        }
    }

    It 'backup scriptはrollback root外への書き込みを拒否する' {
        {
            & $script:backupScript -DestinationRoot (Join-Path $TestDrive 'outside-backup')
        } | Should -Throw '*outside the allowed root*'
        Test-Path -LiteralPath (Join-Path $TestDrive 'outside-backup') | Should -BeFalse
    }

    It 'candidate builderは既存output rootを拒否し現行payloadを変更しない' {
        $before = Get-PayloadSnapshot

        {
            & $script:builder -OutputRoot $script:projectRoot
        } | Should -Throw '*already exists*'

        (Get-PayloadSnapshot) | Should -Be $before
    }

    It 'payload baselineの有無に応じてbackup manifestを要求する' {
        if (Test-Path -LiteralPath $script:payloadRoot -PathType Container) {
            $output = Join-Path $script:projectRoot '_internal\candidates\missing-backup-test'
            {
                & $script:builder -OutputRoot $output
            } | Should -Throw '*PayloadBackupManifest is required*'
            Test-Path -LiteralPath $output | Should -BeFalse
            return
        }

        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $script:candidateBuilder,
            [ref]$tokens,
            [ref]$parseErrors)
        $parseErrors.Count | Should -Be 0
        $parameter = @($ast.ParamBlock.Parameters | Where-Object {
                $_.Name.VariablePath.UserPath -eq 'PayloadBackupManifest'
            })
        $parameter.Count | Should -Be 1
        @($parameter[0].Attributes | Where-Object {
                $_.Extent.Text -match 'Mandatory'
            }).Count | Should -Be 0
    }

    It 'SDK、NuGet source、lockfile契約が存在する' {
        Test-Path -LiteralPath (Join-Path $script:projectRoot 'global.json') -PathType Leaf |
            Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:projectRoot 'NuGet.config') -PathType Leaf |
            Should -BeTrue
        @(
            Get-ChildItem -LiteralPath $script:projectRoot -Filter 'packages.lock.json' -File -Recurse |
                Where-Object { $_.FullName -notmatch '[\\/](bin|obj|build-cache)[\\/]' }
        ).Count | Should -BeGreaterOrEqual 6
    }

    It '配布READMEはpayloadのEXEとportable設定を案内し開発BATを案内しない' {
        $readme = Get-Content -LiteralPath (
            Join-Path $script:projectRoot 'installer\assets\README-portable.md') -Raw
        $readme | Should -Match 'ImageCompressor\.App\.exe'
        $readme | Should -Match 'settings\.json'
        $readme | Should -Not -Match 'image-compressor\.bat'
        (Get-Content -LiteralPath $script:candidateBuilder -Raw) |
            Should -Match "\`$appReadme = Join-Path \`$projectRoot 'installer\\assets\\README-portable\.md'"
    }

    It '導入launcherは既存実行policyを変更も迂回もしない' {
        $launcher = Get-Content -LiteralPath (
            Join-Path (Split-Path -Parent $script:projectRoot) 'ここから開始 - Image Compressorを導入・更新.bat') -Raw
        $launcher | Should -Not -Match '(?i)-ExecutionPolicy|Set-ExecutionPolicy|Unblock-File|EncodedCommand'
        $launcher | Should -Match 'powershell\.exe -STA -NoLogo -NoProfile -File'
    }

    It '正規source digestはsrc配下のbinとobj生成物に依存しない' {
        $tokens = $null
        $parseErrors = $null
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            $script:candidateBuilder,
            [ref]$tokens,
            [ref]$parseErrors)
        $parseErrors.Count | Should -Be 0
        $functionAst = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Get-CanonicalSourceDigest'
            }, $true)
        $functionAst | Should -Not -BeNullOrEmpty
        Invoke-Expression $functionAst.Extent.Text

        $workspaceRoot = Join-Path $TestDrive 'workspace'
        $facadeRoot = Join-Path $workspaceRoot 'image-compressor'
        $projectRoot = Join-Path $facadeRoot 'project'
        foreach ($relativeDirectory in @(
                'src\App',
                'src\App\bin\Release',
                'src\App\obj\Release',
                'installer\assets',
                'scripts')) {
            New-Item -Path (Join-Path $projectRoot $relativeDirectory) -ItemType Directory -Force |
                Out-Null
        }

        foreach ($relativeFile in @(
                'ImageCompressor.slnx',
                'Directory.Build.props',
                'Directory.Packages.props',
                'global.json',
                'NuGet.config',
                'README.md',
                'image-compressor.bat',
                'installer\Install-ImageCompressor.ps1',
                'installer\README.md',
                'installer\assets\settings.json',
                'scripts\_secret-path-guard.ps1',
                'scripts\backup-image-compressor-payload.ps1',
                'scripts\build-image-compressor-installer-package.ps1',
                'scripts\new-image-compressor-candidate-package.ps1',
                'src\App\Program.cs',
                'src\App\packages.lock.json')) {
            $path = Join-Path $projectRoot $relativeFile
            New-Item -Path (Split-Path -Parent $path) -ItemType Directory -Force | Out-Null
            Set-Content -LiteralPath $path -Value $relativeFile -Encoding utf8NoBOM
        }
        Set-Content -LiteralPath (Join-Path $facadeRoot 'README.md') -Value 'facade' -Encoding utf8NoBOM
        Set-Content -LiteralPath (Join-Path $facadeRoot 'LICENSE') -Value 'original-license' -Encoding utf8NoBOM
        Set-Content `
            -LiteralPath (Join-Path $facadeRoot 'ここから開始 - Image Compressorを導入・更新.bat') `
            -Value 'launcher' `
            -Encoding utf8NoBOM

        $before = Get-CanonicalSourceDigest `
            -ProjectRoot $projectRoot `
            -FacadeRoot $facadeRoot `
            -WorkspaceRoot $workspaceRoot
        Set-Content `
            -LiteralPath (Join-Path $projectRoot 'src\App\bin\Release\generated.dll') `
            -Value 'generated-bin' `
            -Encoding utf8NoBOM
        Set-Content `
            -LiteralPath (Join-Path $projectRoot 'src\App\obj\Release\generated.cache') `
            -Value 'generated-obj' `
            -Encoding utf8NoBOM
        $afterGeneratedFiles = Get-CanonicalSourceDigest `
            -ProjectRoot $projectRoot `
            -FacadeRoot $facadeRoot `
            -WorkspaceRoot $workspaceRoot
        $afterGeneratedFiles | Should -Be $before

        Set-Content `
            -LiteralPath (Join-Path $projectRoot 'src\App\Program.cs') `
            -Value 'changed-source' `
            -Encoding utf8NoBOM
        $afterSourceChange = Get-CanonicalSourceDigest `
            -ProjectRoot $projectRoot `
            -FacadeRoot $facadeRoot `
            -WorkspaceRoot $workspaceRoot
        $afterSourceChange | Should -Not -Be $before

        Set-Content -LiteralPath (Join-Path $facadeRoot 'LICENSE') -Value 'changed-license' -Encoding utf8NoBOM
        $afterLicenseChange = Get-CanonicalSourceDigest `
            -ProjectRoot $projectRoot `
            -FacadeRoot $facadeRoot `
            -WorkspaceRoot $workspaceRoot
        $afterLicenseChange | Should -Not -Be $afterSourceChange

        Set-Content -LiteralPath (Join-Path $projectRoot 'installer\assets\README-portable.md') `
            -Value 'portable-readme' -Encoding utf8NoBOM
        $afterReadmeChange = Get-CanonicalSourceDigest `
            -ProjectRoot $projectRoot -FacadeRoot $facadeRoot -WorkspaceRoot $workspaceRoot
        $afterReadmeChange | Should -Not -Be $afterLicenseChange
    }
}
