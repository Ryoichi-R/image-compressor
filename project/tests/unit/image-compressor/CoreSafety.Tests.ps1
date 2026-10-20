#Requires -Modules Pester

BeforeAll {
    Import-Module (
        Join-Path $PSScriptRoot '..\..\..\lib\ImageCompressor.Core.psm1'
    ) -Force
}

Describe 'Get-ImageCompressorResizeDimensions' {
    It '極端な縦横比でも0ピクセルを返さない' {
        $result = Get-ImageCompressorResizeDimensions `
            -Width 1 -Height 99999 -MaxWidth 1 -MaxHeight 1

        $result.Width | Should -Be 1
        $result.Height | Should -Be 1
    }

    It '最大寸法より小さい画像を拡大しない' {
        $result = Get-ImageCompressorResizeDimensions `
            -Width 320 -Height 240 -MaxWidth 1920 -MaxHeight 1080

        $result.Width | Should -Be 320
        $result.Height | Should -Be 240
        $result.Scale | Should -Be 1
    }
}

Describe 'Format-ImageCompressorSizeChange' {
    It '縮小時は削減と表示する' {
        Format-ImageCompressorSizeChange `
            -OriginalBytes 1000 -OutputBytes 750 |
            Should -Be '25.0%削減'
    }

    It '増加時は増加と表示する' {
        Format-ImageCompressorSizeChange `
            -OriginalBytes 1000 -OutputBytes 1250 |
            Should -Be '25.0%増加'
    }
}

Describe 'New-ImageCompressorOutputPlan' {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:inputDir = Join-Path $caseRoot 'input'
        $script:outputDir = Join-Path $caseRoot 'output'
        New-Item -ItemType Directory -Path $script:inputDir -Force | Out-Null
        New-Item -ItemType Directory -Path $script:outputDir -Force | Out-Null
    }

    It '衝突がなければ元のベース名を使用する' {
        $inputPath = Join-Path $script:inputDir 'photo.png'
        New-Item -ItemType File -Path $inputPath | Out-Null

        $plan = New-ImageCompressorOutputPlan `
            -InputFiles (Get-Item -LiteralPath $inputPath) `
            -OutputDirectory $script:outputDir `
            -OutputExtension '.jpg' `
            -CollisionPolicy AutoRename

        $plan.OutputName | Should -Be 'photo.jpg'
        $plan.Action | Should -Be 'Write'
    }

    It '既存ファイルと同一バッチ内の同名を連番で回避する' {
        $jpgPath = Join-Path $script:inputDir 'photo.jpg'
        $pngPath = Join-Path $script:inputDir 'photo.png'
        New-Item -ItemType File -Path $jpgPath | Out-Null
        New-Item -ItemType File -Path $pngPath | Out-Null
        New-Item -ItemType File -Path (
            Join-Path $script:outputDir 'photo.jpg'
        ) | Out-Null

        $plan = New-ImageCompressorOutputPlan `
            -InputFiles @(
                (Get-Item -LiteralPath $jpgPath),
                (Get-Item -LiteralPath $pngPath)
            ) `
            -OutputDirectory $script:outputDir `
            -OutputExtension '.jpg' `
            -CollisionPolicy AutoRename

        $plan[0].OutputName | Should -Be 'photo_001.jpg'
        $plan[1].OutputName | Should -Be 'photo_002.jpg'
        $plan.Action | Should -Not -Contain 'Overwrite'
    }

    It 'スキップ方針では既存ファイルを変更対象にしない' {
        $inputPath = Join-Path $script:inputDir 'photo.png'
        New-Item -ItemType File -Path $inputPath | Out-Null
        New-Item -ItemType File -Path (
            Join-Path $script:outputDir 'photo.jpg'
        ) | Out-Null

        $plan = New-ImageCompressorOutputPlan `
            -InputFiles (Get-Item -LiteralPath $inputPath) `
            -OutputDirectory $script:outputDir `
            -OutputExtension '.jpg' `
            -CollisionPolicy Skip

        $plan.Action | Should -Be 'Skip'
    }

    It '上書き方針では既存ファイルを安全置換対象にする' {
        $inputPath = Join-Path $script:inputDir 'photo.png'
        New-Item -ItemType File -Path $inputPath | Out-Null
        New-Item -ItemType File -Path (
            Join-Path $script:outputDir 'photo.jpg'
        ) | Out-Null

        $plan = New-ImageCompressorOutputPlan `
            -InputFiles (Get-Item -LiteralPath $inputPath) `
            -OutputDirectory $script:outputDir `
            -OutputExtension '.jpg' `
            -CollisionPolicy Overwrite

        $plan.Action | Should -Be 'Overwrite'
    }
}
