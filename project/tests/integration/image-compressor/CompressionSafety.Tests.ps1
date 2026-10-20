#Requires -Modules Pester

Set-StrictMode -Version Latest

BeforeAll {
    $script:appPath = Join-Path (
        Join-Path $PSScriptRoot '..\..\..'
    ) 'image-compressor.ps1'
    . $script:appPath -NoGui

    function New-TestImage {
        param(
            [Parameter(Mandatory)][string]$Path,
            [int]$Width = 12,
            [int]$Height = 12,
            [ValidateSet('PNG', 'BMP')][string]$Format = 'PNG'
        )

        $bitmap = New-Object System.Drawing.Bitmap(
            $Width,
            $Height,
            [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([System.Drawing.Color]::Transparent)
            $graphics.FillRectangle(
                [System.Drawing.Brushes]::Red,
                2,
                2,
                [Math]::Max(1, $Width - 4),
                [Math]::Max(1, $Height - 4))
            $imageFormat = if ($Format -eq 'BMP') {
                [System.Drawing.Imaging.ImageFormat]::Bmp
            } else {
                [System.Drawing.Imaging.ImageFormat]::Png
            }
            $bitmap.Save($Path, $imageFormat)
        } finally {
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    }

    function Set-TestControls {
        param(
            [Parameter(Mandatory)][string]$InputDirectory,
            [Parameter(Mandatory)][string]$OutputDirectory,
            [string]$LargerOutput = '常に保存'
        )

        $txtInput.Text = $InputDirectory
        $txtOutput.Text = $OutputDirectory
        $numMaxW.Value = 100
        $numMaxH.Value = 100
        $numQuality.Value = 75
        $cmbFormat.SelectedItem = 'JPEG'
        $cmbCollisionPolicy.SelectedItem = '自動連番（推奨）'
        $cmbJpegBackground.SelectedItem = '白'
        $cmbLargerOutput.SelectedItem = $LargerOutput
        $txtLog.Clear()
    }
}

AfterAll {
    if ($form) { $form.Dispose() }
}

Describe 'Image Compressor P0 safety' -Tag 'WindowsOnly' -Skip:(-not $IsWindows) {
    BeforeEach {
        $caseRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:inputDir = Join-Path $caseRoot 'input'
        $script:outputDir = Join-Path $caseRoot 'output'
        New-Item -ItemType Directory -Path $script:inputDir -Force | Out-Null
        Set-TestControls `
            -InputDirectory $script:inputDir `
            -OutputDirectory $script:outputDir
    }

    It '透明PNGを明示的な白背景のJPEGとして安全保存する' {
        $inputPath = Join-Path $script:inputDir 'transparent.png'
        New-TestImage -Path $inputPath

        Invoke-Compress -TargetFiles (Get-Item -LiteralPath $inputPath)

        $outputPath = Join-Path $script:outputDir 'transparent.jpg'
        $outputPath | Should -Exist
        $outputImage = [System.Drawing.Bitmap]::FromFile($outputPath)
        try {
            $corner = $outputImage.GetPixel(0, 0)
            $corner.R | Should -BeGreaterThan 240
            $corner.G | Should -BeGreaterThan 240
            $corner.B | Should -BeGreaterThan 240
        } finally {
            $outputImage.Dispose()
        }
        @(Get-ChildItem -LiteralPath $script:outputDir -Filter '*.tmp').Count |
            Should -Be 0
    }

    It 'PNG出力ではJPEG専用の品質と背景色を無効化する' {
        $cmbFormat.SelectedItem = 'PNG'

        $numQuality.Enabled | Should -BeFalse
        $cmbJpegBackground.Enabled | Should -BeFalse
    }

    It '単一フレームGIFのフレーム数を判定できる' {
        $gifPath = Join-Path $script:inputDir 'single.gif'
        $bitmap = New-Object System.Drawing.Bitmap(4, 4)
        try {
            $bitmap.Save(
                $gifPath,
                [System.Drawing.Imaging.ImageFormat]::Gif)
        } finally {
            $bitmap.Dispose()
        }

        Get-ImageFrameCount -Path $gifPath | Should -Be 1
    }

    It '既存ファイルとバッチ内同名を連番で回避する' {
        $pngPath = Join-Path $script:inputDir 'photo.png'
        $bmpPath = Join-Path $script:inputDir 'photo.bmp'
        New-TestImage -Path $pngPath -Format PNG
        New-TestImage -Path $bmpPath -Format BMP
        [IO.Directory]::CreateDirectory($script:outputDir) | Out-Null
        $existingPath = Join-Path $script:outputDir 'photo.jpg'
        Set-Content -LiteralPath $existingPath -Value 'keep' -NoNewline

        Invoke-Compress -TargetFiles @(
            (Get-Item -LiteralPath $pngPath),
            (Get-Item -LiteralPath $bmpPath)
        )

        Get-Content -LiteralPath $existingPath -Raw | Should -Be 'keep'
        (Join-Path $script:outputDir 'photo_001.jpg') | Should -Exist
        (Join-Path $script:outputDir 'photo_002.jpg') | Should -Exist
    }

    It '上書き方針でも一時保存の検証後に既存画像を置換する' {
        $inputPath = Join-Path $script:inputDir 'replace.png'
        New-TestImage -Path $inputPath
        [IO.Directory]::CreateDirectory($script:outputDir) | Out-Null
        $outputPath = Join-Path $script:outputDir 'replace.jpg'
        New-TestImage -Path $outputPath -Format BMP
        $beforeHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $outputPath).Hash
        $cmbCollisionPolicy.SelectedItem = '上書き'

        Invoke-Compress -TargetFiles (Get-Item -LiteralPath $inputPath)

        $txtLog.Text |
            Should -Match '\[  OK  \]' -Because $txtLog.Text
        $afterHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $outputPath).Hash
        $afterHash | Should -Not -Be $beforeHash
        $outputImage = [System.Drawing.Image]::FromFile($outputPath)
        try {
            $outputImage.RawFormat.Guid |
                Should -Be ([System.Drawing.Imaging.ImageFormat]::Jpeg.Guid)
        } finally {
            $outputImage.Dispose()
        }
        @(Get-ChildItem -LiteralPath $script:outputDir -Filter '*.tmp').Count |
            Should -Be 0
    }

    It '出力が元より大きい場合は既定方針で保存しない' {
        Set-TestControls `
            -InputDirectory $script:inputDir `
            -OutputDirectory $script:outputDir `
            -LargerOutput '保存しない（推奨）'
        $inputPath = Join-Path $script:inputDir 'one-pixel.png'
        New-TestImage -Path $inputPath -Width 1 -Height 1

        Invoke-Compress -TargetFiles (Get-Item -LiteralPath $inputPath)

        (Join-Path $script:outputDir 'one-pixel.jpg') | Should -Not -Exist
        $txtLog.Text | Should -Match '元より大きくなるため保存しません'
        @(Get-ChildItem -LiteralPath $script:outputDir -Filter '*.tmp').Count |
            Should -Be 0
    }
}
