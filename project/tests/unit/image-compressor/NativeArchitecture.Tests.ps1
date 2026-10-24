BeforeAll {
    $installer = Join-Path $PSScriptRoot '../../../installer/Install-ImageCompressor.ps1'
    $tokens = $null
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile(
        $installer, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw 'Installer parse failed' }
    foreach ($name in @(
            'ConvertTo-ImageCompressorRuntime',
            'Get-ImageCompressorNativeMachine',
            'Get-ImageCompressorNativeRuntime')) {
        $definition = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq $name
            }, $true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
}

Describe 'Image Compressor native architecture selection' {
    It 'native 0x<NativeMachine> selects <Expected> despite parent <Parent>/<Wow>' -TestCases @(
        @{ NativeMachine = 0xAA64; Parent = 'ARM64'; Wow = ''; Expected = 'win-arm64' },
        @{ NativeMachine = 0xAA64; Parent = 'AMD64'; Wow = ''; Expected = 'win-arm64' },
        @{ NativeMachine = 0xAA64; Parent = 'x86'; Wow = 'ARM64'; Expected = 'win-arm64' },
        @{ NativeMachine = 0x8664; Parent = 'AMD64'; Wow = ''; Expected = 'win-x64' },
        @{ NativeMachine = 0x8664; Parent = 'x86'; Wow = 'AMD64'; Expected = 'win-x64' }
    ) {
        param($NativeMachine, $Parent, $Wow, $Expected)
        $script:detectedMachine = $NativeMachine
        Mock Get-ImageCompressorNativeMachine { $script:detectedMachine }
        $savedParent = $env:PROCESSOR_ARCHITECTURE
        $savedWow = $env:PROCESSOR_ARCHITEW6432
        try {
            $env:PROCESSOR_ARCHITECTURE = $Parent
            $env:PROCESSOR_ARCHITEW6432 = $Wow
            Get-ImageCompressorNativeRuntime | Should -Be $Expected
            Should -Invoke Get-ImageCompressorNativeMachine -Times 1 -Exactly
        }
        finally {
            $env:PROCESSOR_ARCHITECTURE = $savedParent
            $env:PROCESSOR_ARCHITEW6432 = $savedWow
        }
    }

    It 'refuses unsupported native machine 0x<Machine> instead of using the parent' -TestCases @(
        @{ Machine = 0 }, @{ Machine = 0x014c }, @{ Machine = 0xFFFF }
    ) {
        param($Machine)
        $script:detectedMachine = $Machine
        Mock Get-ImageCompressorNativeMachine { $script:detectedMachine }
        { Get-ImageCompressorNativeRuntime } | Should -Throw '*Installation stopped*Unsupported native Windows architecture*'
    }

    It 'propagates a native-query failure without falling back to environment variables' {
        Mock Get-ImageCompressorNativeMachine { throw 'Synthetic native API failure' }
        { Get-ImageCompressorNativeRuntime } | Should -Throw '*Installation stopped*Synthetic native API failure*'
    }
}
