BeforeAll {
    $script:projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
    $script:scriptsRoot = Join-Path $script:projectRoot 'scripts'
    . (Join-Path $script:scriptsRoot '_secret-path-guard.ps1')
    function New-ToolFixture([string]$Name) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $project = Join-Path $root 'image-compressor/project'
        [IO.Directory]::CreateDirectory((Join-Path $project 'scripts')) | Out-Null
        foreach ($file in @($Name, '_secret-path-guard.ps1')) {
            Copy-Item -LiteralPath (Join-Path $script:scriptsRoot $file) -Destination (Join-Path $project 'scripts')
        }
        return $project
    }
}

Describe 'standalone image-compressor secret path guards' {
    It 'rejects all workspace secret patterns including ancestors before I/O' {
        foreach ($name in @('.env', '.env.test', 'secrets.test', 'synthetic.key', 'synthetic.pem', 'synthetic.pfx', 'synthetic.p12', 'credentials.test')) {
            Test-SecretFilePath -FilePath (Join-Path $TestDrive $name) | Should -BeTrue
            { Assert-SafeFilePath -Path (Join-Path $TestDrive "$name/child.txt") } | Should -Throw '*SECRET_PATH_REJECTED*'
        }
        Test-SecretFilePath -FilePath (Join-Path $TestDrive 'settings.example.json') | Should -BeFalse
        Test-SecretFilePath -FilePath (Join-Path $TestDrive '.env:synthetic-stream') | Should -BeTrue
        { Assert-SafeFilePath -Path (Join-Path $TestDrive 'future/safe.json') } | Should -Not -Throw
    }

    It 'refuses a secret member in a recursive tree without opening its content' {
        $root = Join-Path $TestDrive 'synthetic-tree'
        [IO.Directory]::CreateDirectory($root) | Out-Null
        [IO.File]::WriteAllText((Join-Path $root '.env.synthetic'), 'synthetic-only')
        Mock Get-Content { throw 'content must not be read' }
        { Assert-SafeFileTree -Path $root } | Should -Throw '*SECRET_PATH_REJECTED*'
        Should -Invoke Get-Content -Times 0 -Exactly
    }

    It 'backup refuses a secret destination without creating it' {
        $project = New-ToolFixture 'backup-image-compressor-payload.ps1'
        $target = Join-Path $project '_internal/rollback/.env'
        { & (Join-Path $project 'scripts/backup-image-compressor-payload.ps1') -DestinationRoot $target } | Should -Throw '*SECRET_PATH_REJECTED*'
        Test-Path -LiteralPath $target | Should -BeFalse
    }

    It 'candidate generation refuses a secret output before invoking dotnet' {
        $project = New-ToolFixture 'new-image-compressor-candidate-package.ps1'
        $target = Join-Path $project '_internal/candidates/secrets.synthetic'
        { & (Join-Path $project 'scripts/new-image-compressor-candidate-package.ps1') -OutputRoot $target } | Should -Throw '*SECRET_PATH_REJECTED*'
        Test-Path -LiteralPath $target | Should -BeFalse
    }

    It 'promotion refuses a secret candidate before reading its receipt' {
        $project = New-ToolFixture 'promote-image-compressor-candidate.ps1'
        { & (Join-Path $project 'scripts/promote-image-compressor-candidate.ps1') -CandidateRoot (Join-Path $project '_internal/candidates/.env') -PayloadBackupManifest (Join-Path $project '_internal/rollback/synthetic.json') -WhatIf } | Should -Throw '*SECRET_PATH_REJECTED*'
    }

    It 'legacy benchmark refuses secret inputs and outputs before creating directories' {
        $project = New-ToolFixture 'measure-image-compressor-legacy-baseline.ps1'
        foreach ($operand in @('FixtureRoot', 'OutputRoot', 'ReportPath')) {
            $arguments = @{ FixtureRoot = (Join-Path $TestDrive 'safe-input'); OutputRoot = (Join-Path $TestDrive 'safe-output'); ReportPath = (Join-Path $TestDrive 'report.json'); Count = 1; Runs = 1 }
            $arguments[$operand] = Join-Path $TestDrive '.env.synthetic'
            { & (Join-Path $project 'scripts/measure-image-compressor-legacy-baseline.ps1') @arguments } | Should -Throw '*SECRET_PATH_REJECTED*'
        }
        Test-Path -LiteralPath (Join-Path $TestDrive 'safe-output') | Should -BeFalse
    }

    It 'naming checker refuses secret ancestors before reading CSharp sources' {
        $project = New-ToolFixture 'check-image-compressor-test-naming.ps1'
        $secretRoot = Join-Path $project 'tests/unit/image-compressor-dotnet/.env.synthetic'
        [IO.Directory]::CreateDirectory($secretRoot) | Out-Null
        [IO.File]::WriteAllText((Join-Path $secretRoot 'synthetic.cs'), 'synthetic-only')
        { & (Join-Path $project 'scripts/check-image-compressor-test-naming.ps1') } | Should -Throw '*SECRET_PATH_REJECTED*'
    }

    It 'normal backup still copies and verifies an allowed synthetic payload' {
        $project = New-ToolFixture 'backup-image-compressor-payload.ps1'
        $payload = Join-Path $project 'installer/payload'
        $rollback = Join-Path $project '_internal/rollback'
        [IO.Directory]::CreateDirectory($payload) | Out-Null
        [IO.Directory]::CreateDirectory($rollback) | Out-Null
        [IO.File]::WriteAllText((Join-Path $payload 'payload-manifest.json'), '{"productVersion":"0.0.1"}')
        [IO.File]::WriteAllText((Join-Path $payload 'synthetic.zip'), 'synthetic payload bytes')
        [IO.File]::WriteAllText((Join-Path $project '.env.synthetic'), 'synthetic unrelated input; must not be opened or copied')
        $target = Join-Path $rollback 'new-test-backup'
        & (Join-Path $project 'scripts/backup-image-compressor-payload.ps1') -DestinationRoot $target
        (Get-FileHash -LiteralPath (Join-Path $target 'payload/synthetic.zip')).Hash | Should -Be (Get-FileHash -LiteralPath (Join-Path $payload 'synthetic.zip')).Hash
        $manifest = Get-Content -LiteralPath (Join-Path $target 'payload-backup-manifest.json') -Raw | ConvertFrom-Json
        $manifest.files.Count | Should -Be 2
        Test-Path -LiteralPath (Join-Path $target 'payload/.env.synthetic') | Should -BeFalse
    }

    It 'does not reject or read an unrelated secret file outside naming-check operands' {
        $project = New-ToolFixture 'check-image-compressor-test-naming.ps1'
        $tests = Join-Path $project 'tests/unit/image-compressor-dotnet'
        [IO.Directory]::CreateDirectory($tests) | Out-Null
        [IO.File]::WriteAllText((Join-Path $tests '.env.synthetic'), 'synthetic unrelated input; must not be opened')
        Mock Get-Content { throw 'unrelated content must not be read' }
        { & (Join-Path $project 'scripts/check-image-compressor-test-naming.ps1') } | Should -Not -Throw
        Should -Invoke Get-Content -Times 0 -Exactly
    }
}
