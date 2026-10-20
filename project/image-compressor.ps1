#Requires -Version 5.1
<#
.SYNOPSIS
    画像圧縮ツール (GUI)
.DESCRIPTION
    画像ファイル (jpg/jpeg/png/bmp/gif/tiff) をリサイズ・圧縮する。
    入力フォルダと出力フォルダを指定し、EXIF回転補正付きで一括処理。
#>

[CmdletBinding()]
param(
    [switch]$NoGui
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Import-Module (
    Join-Path $PSScriptRoot 'lib\ImageCompressor.Core.psm1'
) -Force

# === Hide console window ===
if (-not ('Native.Win32' -as [type])) {
    Add-Type -Name Win32 -Namespace Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
}
if (-not $NoGui) {
    $consoleHwnd = [Native.Win32]::GetConsoleWindow()
    if ($consoleHwnd -ne [IntPtr]::Zero) {
        [Native.Win32]::ShowWindow($consoleHwnd, 0) | Out-Null  # SW_HIDE
    }
}

# === Default Settings ===
$picturesDir = [Environment]::GetFolderPath(
    [Environment+SpecialFolder]::MyPictures)
if ([string]::IsNullOrWhiteSpace($picturesDir)) {
    $picturesDir = [Environment]::GetFolderPath(
        [Environment+SpecialFolder]::UserProfile)
}
$DefaultInputDir = Join-Path $picturesDir 'pre-image compression'
$DefaultOutputDir = Join-Path $picturesDir 'image compression'

$ImageExtensions = @('.jpg', '.jpeg', '.png', '.bmp', '.gif', '.tiff', '.tif')

# EXIF Orientation tag ID (0x0112)
$ExifOrientationTagId = 0x0112

$Presets = @{
    'デフォルト'   = @{ MaxW = 1920; MaxH = 1080; Quality = 75; Format = 'JPEG' }
    'HD'          = @{ MaxW = 1280; MaxH = 720;  Quality = 80; Format = 'JPEG' }
    '4K'          = @{ MaxW = 3840; MaxH = 2160; Quality = 85; Format = 'JPEG' }
    '高品質'       = @{ MaxW = 1920; MaxH = 1080; Quality = 95; Format = 'PNG'  }
    'Web最適化'    = @{ MaxW = 1200; MaxH = 800;  Quality = 60; Format = 'JPEG' }
    'サムネイル'    = @{ MaxW = 320;  MaxH = 240;  Quality = 70; Format = 'JPEG' }
}

# === Script-level state ===
$script:scanValid = $false
$script:cachedFiles = @()
$script:progressTotal = 0
$script:progressCurrent = 0

# === Build GUI ===
$form = New-Object System.Windows.Forms.Form
$form.Text = '画像圧縮ツール'
$form.Size = New-Object System.Drawing.Size(620, 800)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Yu Gothic UI', 9)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

$y = 12

# --- Input folder ---
$lblInput = New-Object System.Windows.Forms.Label
$lblInput.Text = '入力フォルダ'
$lblInput.Location = New-Object System.Drawing.Point(12, $y)
$lblInput.AutoSize = $true
$form.Controls.Add($lblInput)
$y += 20

$txtInput = New-Object System.Windows.Forms.TextBox
$txtInput.Text = $DefaultInputDir
$txtInput.Location = New-Object System.Drawing.Point(12, $y)
$txtInput.Size = New-Object System.Drawing.Size(460, 24)
$form.Controls.Add($txtInput)

$btnBrowseInput = New-Object System.Windows.Forms.Button
$btnBrowseInput.Text = '...'
$btnBrowseInput.Location = New-Object System.Drawing.Point(478, ($y - 1))
$btnBrowseInput.Size = New-Object System.Drawing.Size(50, 24)
$btnBrowseInput.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.SelectedPath = $txtInput.Text
    if ($dlg.ShowDialog() -eq 'OK') { $txtInput.Text = $dlg.SelectedPath }
})
$form.Controls.Add($btnBrowseInput)

$btnOpenInput = New-Object System.Windows.Forms.Button
$btnOpenInput.Text = '開く'
$btnOpenInput.Location = New-Object System.Drawing.Point(534, ($y - 1))
$btnOpenInput.Size = New-Object System.Drawing.Size(54, 24)
$btnOpenInput.Add_Click({
    $dir = $txtInput.Text.Trim()
    if (Test-Path -LiteralPath $dir -PathType Container) {
        Invoke-Item -LiteralPath $dir
    }
})
$form.Controls.Add($btnOpenInput)
$y += 30

# --- Output folder ---
$lblOutput = New-Object System.Windows.Forms.Label
$lblOutput.Text = '出力フォルダ'
$lblOutput.Location = New-Object System.Drawing.Point(12, $y)
$lblOutput.AutoSize = $true
$form.Controls.Add($lblOutput)
$y += 20

$txtOutput = New-Object System.Windows.Forms.TextBox
$txtOutput.Text = $DefaultOutputDir
$txtOutput.Location = New-Object System.Drawing.Point(12, $y)
$txtOutput.Size = New-Object System.Drawing.Size(460, 24)
$form.Controls.Add($txtOutput)

$btnBrowseOutput = New-Object System.Windows.Forms.Button
$btnBrowseOutput.Text = '...'
$btnBrowseOutput.Location = New-Object System.Drawing.Point(478, ($y - 1))
$btnBrowseOutput.Size = New-Object System.Drawing.Size(50, 24)
$btnBrowseOutput.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    $dlg.SelectedPath = $txtOutput.Text
    if ($dlg.ShowDialog() -eq 'OK') { $txtOutput.Text = $dlg.SelectedPath }
})
$form.Controls.Add($btnBrowseOutput)

$btnOpenOutput = New-Object System.Windows.Forms.Button
$btnOpenOutput.Text = '開く'
$btnOpenOutput.Location = New-Object System.Drawing.Point(534, ($y - 1))
$btnOpenOutput.Size = New-Object System.Drawing.Size(54, 24)
$btnOpenOutput.Add_Click({
    $dir = $txtOutput.Text.Trim()
    if (Test-Path -LiteralPath $dir -PathType Container) {
        Invoke-Item -LiteralPath $dir
    }
})
$form.Controls.Add($btnOpenOutput)
$y += 36

# --- Preset ---
$lblPreset = New-Object System.Windows.Forms.Label
$lblPreset.Text = 'プリセット'
$lblPreset.Location = New-Object System.Drawing.Point(12, $y)
$lblPreset.AutoSize = $true
$form.Controls.Add($lblPreset)

$cmbPreset = New-Object System.Windows.Forms.ComboBox
$cmbPreset.DropDownStyle = 'DropDownList'
$cmbPreset.Location = New-Object System.Drawing.Point(90, ($y - 2))
$cmbPreset.Size = New-Object System.Drawing.Size(140, 24)
$cmbPreset.Items.AddRange(@('デフォルト', 'HD', '4K', '高品質', 'Web最適化', 'サムネイル'))
$cmbPreset.SelectedIndex = 0
$form.Controls.Add($cmbPreset)
$y += 32

# --- Parameters grid ---
$paramY = $y

# Max Width
$lblMaxW = New-Object System.Windows.Forms.Label
$lblMaxW.Text = '最大幅 (px)'
$lblMaxW.Location = New-Object System.Drawing.Point(12, $paramY)
$lblMaxW.AutoSize = $true
$form.Controls.Add($lblMaxW)

$numMaxW = New-Object System.Windows.Forms.NumericUpDown
$numMaxW.Location = New-Object System.Drawing.Point(150, ($paramY - 2))
$numMaxW.Size = New-Object System.Drawing.Size(80, 24)
$numMaxW.Minimum = 1; $numMaxW.Maximum = 99999; $numMaxW.Value = 1920
$form.Controls.Add($numMaxW)

# Max Height
$lblMaxH = New-Object System.Windows.Forms.Label
$lblMaxH.Text = '最大高さ (px)'
$lblMaxH.Location = New-Object System.Drawing.Point(300, $paramY)
$lblMaxH.AutoSize = $true
$form.Controls.Add($lblMaxH)

$numMaxH = New-Object System.Windows.Forms.NumericUpDown
$numMaxH.Location = New-Object System.Drawing.Point(440, ($paramY - 2))
$numMaxH.Size = New-Object System.Drawing.Size(80, 24)
$numMaxH.Minimum = 1; $numMaxH.Maximum = 99999; $numMaxH.Value = 1080
$form.Controls.Add($numMaxH)
$paramY += 30

# Quality
$lblQuality = New-Object System.Windows.Forms.Label
$lblQuality.Text = '品質 (0-100)'
$lblQuality.Location = New-Object System.Drawing.Point(12, $paramY)
$lblQuality.AutoSize = $true
$form.Controls.Add($lblQuality)

$numQuality = New-Object System.Windows.Forms.NumericUpDown
$numQuality.Location = New-Object System.Drawing.Point(150, ($paramY - 2))
$numQuality.Size = New-Object System.Drawing.Size(80, 24)
$numQuality.Minimum = 1; $numQuality.Maximum = 100; $numQuality.Value = 75
$form.Controls.Add($numQuality)

# Output Format
$lblFormat = New-Object System.Windows.Forms.Label
$lblFormat.Text = '出力形式'
$lblFormat.Location = New-Object System.Drawing.Point(300, $paramY)
$lblFormat.AutoSize = $true
$form.Controls.Add($lblFormat)

$cmbFormat = New-Object System.Windows.Forms.ComboBox
$cmbFormat.DropDownStyle = 'DropDownList'
$cmbFormat.Location = New-Object System.Drawing.Point(440, ($paramY - 2))
$cmbFormat.Size = New-Object System.Drawing.Size(80, 24)
$cmbFormat.Items.AddRange(@('JPEG', 'PNG', 'BMP'))
$cmbFormat.SelectedItem = 'JPEG'
$form.Controls.Add($cmbFormat)
$paramY += 30

# Collision policy
$lblCollisionPolicy = New-Object System.Windows.Forms.Label
$lblCollisionPolicy.Text = '既存ファイル'
$lblCollisionPolicy.Location = New-Object System.Drawing.Point(12, $paramY)
$lblCollisionPolicy.AutoSize = $true
$form.Controls.Add($lblCollisionPolicy)

$cmbCollisionPolicy = New-Object System.Windows.Forms.ComboBox
$cmbCollisionPolicy.DropDownStyle = 'DropDownList'
$cmbCollisionPolicy.Location = New-Object System.Drawing.Point(150, ($paramY - 2))
$cmbCollisionPolicy.Size = New-Object System.Drawing.Size(160, 24)
$cmbCollisionPolicy.Items.AddRange(@(
        '自動連番（推奨）',
        'スキップ',
        '上書き',
        '個別に確認'
    ))
$cmbCollisionPolicy.SelectedIndex = 0
$form.Controls.Add($cmbCollisionPolicy)

# JPEG background
$lblJpegBackground = New-Object System.Windows.Forms.Label
$lblJpegBackground.Text = 'JPEG背景色'
$lblJpegBackground.Location = New-Object System.Drawing.Point(330, $paramY)
$lblJpegBackground.AutoSize = $true
$form.Controls.Add($lblJpegBackground)

$cmbJpegBackground = New-Object System.Windows.Forms.ComboBox
$cmbJpegBackground.DropDownStyle = 'DropDownList'
$cmbJpegBackground.Location = New-Object System.Drawing.Point(440, ($paramY - 2))
$cmbJpegBackground.Size = New-Object System.Drawing.Size(80, 24)
$cmbJpegBackground.Items.AddRange(@('白', '黒'))
$cmbJpegBackground.SelectedItem = '白'
$form.Controls.Add($cmbJpegBackground)
$paramY += 30

# Larger output policy
$lblLargerOutput = New-Object System.Windows.Forms.Label
$lblLargerOutput.Text = '容量が増えた場合'
$lblLargerOutput.Location = New-Object System.Drawing.Point(12, $paramY)
$lblLargerOutput.AutoSize = $true
$form.Controls.Add($lblLargerOutput)

$cmbLargerOutput = New-Object System.Windows.Forms.ComboBox
$cmbLargerOutput.DropDownStyle = 'DropDownList'
$cmbLargerOutput.Location = New-Object System.Drawing.Point(150, ($paramY - 2))
$cmbLargerOutput.Size = New-Object System.Drawing.Size(160, 24)
$cmbLargerOutput.Items.AddRange(@(
        '保存しない（推奨）',
        '警告して保存',
        '常に保存'
    ))
$cmbLargerOutput.SelectedIndex = 0
$form.Controls.Add($cmbLargerOutput)
$paramY += 36

# --- Preset change handler ---
$cmbPreset.Add_SelectedIndexChanged({
    $p = $Presets[$cmbPreset.SelectedItem]
    $numMaxW.Value    = $p.MaxW
    $numMaxH.Value    = $p.MaxH
    $numQuality.Value = $p.Quality
    $cmbFormat.SelectedItem = $p.Format
})

$cmbFormat.Add_SelectedIndexChanged({
    $isJpeg = $cmbFormat.SelectedItem -eq 'JPEG'
    $numQuality.Enabled = $isJpeg
    $lblQuality.Enabled = $isJpeg
    $cmbJpegBackground.Enabled = $isJpeg
    $lblJpegBackground.Enabled = $isJpeg
})

# --- File list section ---
$y = $paramY

$btnScanFiles = New-Object System.Windows.Forms.Button
$btnScanFiles.Text = '確認'
$btnScanFiles.Location = New-Object System.Drawing.Point(12, $y)
$btnScanFiles.Size = New-Object System.Drawing.Size(80, 26)
$form.Controls.Add($btnScanFiles)

$lblSummary = New-Object System.Windows.Forms.Label
$lblSummary.Text = '[確認] を押してファイル一覧を取得'
$lblSummary.Location = New-Object System.Drawing.Point(100, ($y + 4))
$lblSummary.Size = New-Object System.Drawing.Size(488, 20)
$form.Controls.Add($lblSummary)
$y += 28

$dgv = New-Object System.Windows.Forms.DataGridView
$dgv.Location = New-Object System.Drawing.Point(12, $y)
$dgv.Size = New-Object System.Drawing.Size(576, 150)
$dgv.AllowUserToAddRows = $false
$dgv.AllowUserToDeleteRows = $false
$dgv.AllowUserToResizeRows = $false
$dgv.RowHeadersVisible = $false
$dgv.SelectionMode = 'FullRowSelect'
$dgv.BackgroundColor = [System.Drawing.SystemColors]::Window
$dgv.DefaultCellStyle.SelectionBackColor = [System.Drawing.SystemColors]::Window
$dgv.DefaultCellStyle.SelectionForeColor = [System.Drawing.SystemColors]::ControlText

$colCheck = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colCheck.HeaderText = '対象'
$colCheck.Width = 42
$colCheck.Name = 'Target'
$dgv.Columns.Add($colCheck) | Out-Null

$colName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colName.HeaderText = 'ファイル名'
$colName.Width = 250
$colName.Name = 'FileName'
$colName.ReadOnly = $true
$dgv.Columns.Add($colName) | Out-Null

$colExt = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colExt.HeaderText = '拡張子'
$colExt.Width = 55
$colExt.Name = 'Ext'
$colExt.ReadOnly = $true
$dgv.Columns.Add($colExt) | Out-Null

$colDim = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colDim.HeaderText = 'サイズ (px)'
$colDim.Width = 100
$colDim.Name = 'Dimensions'
$colDim.ReadOnly = $true
$dgv.Columns.Add($colDim) | Out-Null

$colSize = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colSize.HeaderText = 'ファイルサイズ'
$colSize.Width = 90
$colSize.Name = 'FileSize'
$colSize.ReadOnly = $true
$dgv.Columns.Add($colSize) | Out-Null

$form.Controls.Add($dgv)
$y += 156

# --- Execute button ---
$btnRun = New-Object System.Windows.Forms.Button
$btnRun.Text = '実行'
$btnRun.Location = New-Object System.Drawing.Point(12, $y)
$btnRun.Size = New-Object System.Drawing.Size(576, 40)
$btnRun.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$btnRun.ForeColor = [System.Drawing.Color]::White
$btnRun.FlatStyle = 'Flat'
$btnRun.Font = New-Object System.Drawing.Font('Yu Gothic UI', 11, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnRun)
$y += 50

# --- Progress bar ---
$lblProgressTitle = New-Object System.Windows.Forms.Label
$lblProgressTitle.Text = '進捗'
$lblProgressTitle.Location = New-Object System.Drawing.Point(12, $y)
$lblProgressTitle.AutoSize = $true
$form.Controls.Add($lblProgressTitle)
$y += 18

$pnlProgressBg = New-Object System.Windows.Forms.Panel
$pnlProgressBg.Location = New-Object System.Drawing.Point(12, $y)
$pnlProgressBg.Size = New-Object System.Drawing.Size(576, 26)
$pnlProgressBg.BackColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
$pnlProgressBg.BorderStyle = 'None'
$form.Controls.Add($pnlProgressBg)

$pnlProgressFill = New-Object System.Windows.Forms.Panel
$pnlProgressFill.Location = New-Object System.Drawing.Point(0, 0)
$pnlProgressFill.Size = New-Object System.Drawing.Size(0, 26)
$pnlProgressFill.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$pnlProgressBg.Controls.Add($pnlProgressFill)

$lblProgress = New-Object System.Windows.Forms.Label
$lblProgress.Text = ''
$lblProgress.Location = New-Object System.Drawing.Point(0, 0)
$lblProgress.Size = New-Object System.Drawing.Size(576, 26)
$lblProgress.TextAlign = 'MiddleCenter'
$lblProgress.ForeColor = [System.Drawing.Color]::White
$lblProgress.BackColor = [System.Drawing.Color]::Transparent
$lblProgress.Font = New-Object System.Drawing.Font('Yu Gothic UI', 9, [System.Drawing.FontStyle]::Bold)
$pnlProgressBg.Controls.Add($lblProgress)
$lblProgress.BringToFront()

$y += 32

# --- Log area ---
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = 'ログ'
$lblLog.Location = New-Object System.Drawing.Point(12, $y)
$lblLog.AutoSize = $true
$form.Controls.Add($lblLog)
$y += 18

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$txtLog.Font = New-Object System.Drawing.Font('Cascadia Code,Consolas,Courier New', 9)
$txtLog.Location = New-Object System.Drawing.Point(12, $y)
$txtLog.Size = New-Object System.Drawing.Size(576, 120)
$form.Controls.Add($txtLog)

# === Core Logic ===
function Write-Log {
    param([string]$Message)
    $txtLog.AppendText("$Message`r`n")
    $txtLog.SelectionStart = $txtLog.TextLength
    $txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Update-Progress {
    param([int]$Current, [int]$Total)
    if ($Total -le 0) { return }
    $pct = [math]::Min(100, [math]::Floor($Current * 100 / $Total))
    $fillWidth = [math]::Floor($pnlProgressBg.Width * $pct / 100)
    $pnlProgressFill.Width = $fillWidth
    $lblProgress.Text = "$Current / $Total 完了 ($pct%)"
    [System.Windows.Forms.Application]::DoEvents()
}

function Reset-Progress {
    $pnlProgressFill.Width = 0
    $lblProgress.Text = ''
    [System.Windows.Forms.Application]::DoEvents()
}

function Format-FileSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N1} KB' -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Get-ImageDimensions {
    param([string]$Path)
    try {
        $img = [System.Drawing.Image]::FromFile($Path)
        $dims = "$($img.Width) x $($img.Height)"
        $img.Dispose()
        return $dims
    } catch {
        return '?'
    }
}

function Set-UIEnabled([bool]$Enabled) {
    $jpegControlsEnabled = (
        $Enabled -and $cmbFormat.SelectedItem -eq 'JPEG')
    $btnRun.Enabled          = $Enabled
    $btnScanFiles.Enabled    = $Enabled
    $txtInput.Enabled        = $Enabled
    $btnBrowseInput.Enabled  = $Enabled
    $txtOutput.Enabled       = $Enabled
    $btnBrowseOutput.Enabled = $Enabled
    $cmbPreset.Enabled       = $Enabled
    $numMaxW.Enabled         = $Enabled
    $numMaxH.Enabled         = $Enabled
    $numQuality.Enabled      = $jpegControlsEnabled
    $lblQuality.Enabled      = $jpegControlsEnabled
    $cmbFormat.Enabled       = $Enabled
    $cmbCollisionPolicy.Enabled = $Enabled
    $cmbJpegBackground.Enabled = $jpegControlsEnabled
    $lblJpegBackground.Enabled = $jpegControlsEnabled
    $cmbLargerOutput.Enabled = $Enabled
    $dgv.Enabled             = $Enabled
}

function Clear-FileListWithError {
    param([string]$Message)
    $dgv.Rows.Clear()
    $lblSummary.Text = "[エラー] $Message"
    $script:scanValid = $false
    $script:cachedFiles = @()
    Write-Log "[ERROR] $Message"
}

function Update-FileGrid {
    $dgv.Rows.Clear()
    $targetCount = 0
    $totalSize = 0L
    $targetSize = 0L
    foreach ($f in $script:cachedFiles) {
        $ext = $f.Extension.ToLower()
        $isTarget = $ext -in $ImageExtensions
        $dims = if ($isTarget) { Get-ImageDimensions -Path $f.FullName } else { '-' }
        $rowIdx = $dgv.Rows.Add($isTarget, $f.Name, $ext, $dims, (Format-FileSize $f.Length))
        if (-not $isTarget) {
            $dgv.Rows[$rowIdx].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
        } else {
            $targetCount++
            $targetSize += $f.Length
        }
        $totalSize += $f.Length
    }
    $total = $script:cachedFiles.Count
    $lblSummary.Text = "対象: ${targetCount}件 / 全 ${total}件 (対象合計 $(Format-FileSize $targetSize) / 全体 $(Format-FileSize $totalSize))"
}

function Update-FileList {
    $inputDir = $txtInput.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($inputDir)) {
        Clear-FileListWithError '入力フォルダパスが空です。'
        return
    }
    if (-not (Test-Path -LiteralPath $inputDir)) {
        Clear-FileListWithError "フォルダが見つかりません: $inputDir"
        return
    }
    if (-not (Test-Path -LiteralPath $inputDir -PathType Container)) {
        Clear-FileListWithError "指定パスはフォルダではありません: $inputDir"
        return
    }

    try {
        $files = Get-ChildItem -LiteralPath $inputDir -File
    } catch {
        Clear-FileListWithError "ファイル列挙に失敗: $($_.Exception.Message)"
        return
    }

    $script:scanValid = $true
    $script:cachedFiles = @($files)
    Update-FileGrid
}

function Fix-ExifOrientation {
    param([System.Drawing.Image]$Image)
    try {
        $prop = $Image.PropertyItems | Where-Object { $_.Id -eq $ExifOrientationTagId }
        if ($prop) {
            switch ($prop.Value[0]) {
                2 { $Image.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipX) }
                3 { $Image.RotateFlip([System.Drawing.RotateFlipType]::Rotate180FlipNone) }
                4 { $Image.RotateFlip([System.Drawing.RotateFlipType]::RotateNoneFlipY) }
                5 { $Image.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipX) }
                6 { $Image.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone) }
                7 { $Image.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipX) }
                8 { $Image.RotateFlip([System.Drawing.RotateFlipType]::Rotate270FlipNone) }
            }
        }
    } catch {
        Write-Log "[WARN ] EXIF Orientation 補正失敗: $($_.Exception.Message)"
    }
}

function Get-OutputExtension {
    param([string]$Format)
    switch ($Format) {
        'JPEG' { return '.jpg' }
        'PNG'  { return '.png' }
        'BMP'  { return '.bmp' }
        default { return '.jpg' }
    }
}

function Get-ImageEncoder {
    param([string]$Format)
    $mime = switch ($Format) {
        'JPEG' { 'image/jpeg' }
        'PNG'  { 'image/png' }
        'BMP'  { 'image/bmp' }
        default { 'image/jpeg' }
    }
    return [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq $mime }
}

function Get-CollisionPolicy {
    switch ($cmbCollisionPolicy.SelectedItem) {
        '自動連番（推奨）' { return 'AutoRename' }
        'スキップ'         { return 'Skip' }
        '上書き'           { return 'Overwrite' }
        '個別に確認'       { return 'Confirm' }
        default            { return 'AutoRename' }
    }
}

function Get-JpegBackgroundColor {
    switch ($cmbJpegBackground.SelectedItem) {
        '黒'     { return [System.Drawing.Color]::Black }
        default  { return [System.Drawing.Color]::White }
    }
}

function Get-ImageFrameCount {
    param([string]$Path)

    $image = $null
    try {
        $image = [System.Drawing.Image]::FromFile($Path)
        $maxFrames = 1
        foreach ($dimensionId in $image.FrameDimensionsList) {
            $dimension = [System.Drawing.Imaging.FrameDimension]::new(
                $dimensionId)
            $maxFrames = [Math]::Max(
                $maxFrames,
                $image.GetFrameCount($dimension))
        }
        return $maxFrames
    } finally {
        if ($image) { $image.Dispose() }
    }
}

function Get-MultiFrameWarnings {
    param([System.IO.FileInfo[]]$Files)

    $warnings = [Collections.Generic.List[string]]::new()
    foreach ($file in $Files) {
        if ($file.Extension.ToLowerInvariant() -notin @('.gif', '.tif', '.tiff')) {
            continue
        }
        try {
            $frameCount = Get-ImageFrameCount -Path $file.FullName
            if ($frameCount -gt 1) {
                $warnings.Add("$($file.Name) ($frameCount フレーム/ページ)")
            }
        } catch {
            Write-Log "[WARN ] フレーム数を確認できません: $($file.Name)"
        }
    }
    return $warnings.ToArray()
}

function Save-ImageSafely {
    param(
        [Parameter(Mandatory)][System.Drawing.Bitmap]$Bitmap,
        [Parameter(Mandatory)]
        [System.Drawing.Imaging.ImageCodecInfo]$Encoder,
        [AllowNull()]
        [System.Drawing.Imaging.EncoderParameters]$EncoderParameters,
        [Parameter(Mandatory)][string]$FinalPath,
        [Parameter(Mandatory)][bool]$AllowReplace,
        [Parameter(Mandatory)][long]$OriginalBytes,
        [Parameter(Mandatory)]
        [ValidateSet('Skip', 'Warn', 'Save')]
        [string]$LargerOutputPolicy
    )

    $finalFull = [IO.Path]::GetFullPath($FinalPath)
    $outputDirectory = [IO.Path]::GetDirectoryName($finalFull)
    $temporaryPath = Join-Path $outputDirectory (
        '.image-compressor-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
    $validationImage = $null

    try {
        $Bitmap.Save($temporaryPath, $Encoder, $EncoderParameters)
        $temporaryInfo = [IO.FileInfo]::new($temporaryPath)
        if (-not $temporaryInfo.Exists -or $temporaryInfo.Length -le 0) {
            throw '一時ファイルが空、または作成されませんでした。'
        }

        $validationImage = [System.Drawing.Image]::FromFile($temporaryPath)
        if ($validationImage.Width -ne $Bitmap.Width -or
            $validationImage.Height -ne $Bitmap.Height) {
            throw '保存後の画像寸法が変換結果と一致しません。'
        }
        $validationImage.Dispose()
        $validationImage = $null

        $outputBytes = $temporaryInfo.Length
        $isLarger = $OriginalBytes -gt 0 -and $outputBytes -gt $OriginalBytes
        if ($isLarger -and $LargerOutputPolicy -eq 'Skip') {
            return [pscustomobject]@{
                Saved       = $false
                FileInfo    = $null
                OutputBytes = $outputBytes
                IsLarger    = $true
            }
        }

        if ([IO.File]::Exists($finalFull)) {
            if (-not $AllowReplace) {
                throw "保存直前に出力ファイルが作成されました: $finalFull"
            }
            [IO.File]::Replace(
                $temporaryPath,
                $finalFull,
                [System.Management.Automation.Language.NullString]::Value)
        } else {
            [IO.File]::Move($temporaryPath, $finalFull)
        }

        return [pscustomobject]@{
            Saved       = $true
            FileInfo    = [IO.FileInfo]::new($finalFull)
            OutputBytes = $outputBytes
            IsLarger    = $isLarger
        }
    } finally {
        if ($validationImage) { $validationImage.Dispose() }
        if ([IO.File]::Exists($temporaryPath)) {
            [IO.File]::Delete($temporaryPath)
        }
    }
}

function Invoke-Compress {
    param([System.IO.FileInfo[]]$TargetFiles)

    $inputDir  = $txtInput.Text.Trim()
    $outputDir = $txtOutput.Text.Trim()
    $maxW      = [int]$numMaxW.Value
    $maxH      = [int]$numMaxH.Value
    $quality   = [int]$numQuality.Value
    $format    = $cmbFormat.SelectedItem
    $collisionPolicy = Get-CollisionPolicy
    $largerOutputPolicy = switch ($cmbLargerOutput.SelectedItem) {
        '警告して保存' { 'Warn' }
        '常に保存'     { 'Save' }
        default        { 'Skip' }
    }

    Write-Log '=== 画像圧縮処理 ==='
    Write-Log ''

    # --- Validation ---
    if ([string]::IsNullOrWhiteSpace($inputDir)) {
        Write-Log '[ERROR] 入力フォルダパスが空です。'; return
    }
    if (-not (Test-Path -LiteralPath $inputDir)) {
        Write-Log "[ERROR] 入力フォルダが見つかりません: $inputDir"; return
    }
    if ([string]::IsNullOrWhiteSpace($outputDir)) {
        Write-Log '[ERROR] 出力フォルダパスが空です。'; return
    }

    # 入力フォルダと出力フォルダが同一の場合、元ファイルを上書きしうるため拒否
    try {
        $inputFull  = [IO.Path]::GetFullPath($inputDir).TrimEnd('\')
        $outputFull = [IO.Path]::GetFullPath($outputDir).TrimEnd('\')
        if ([string]::Equals($inputFull, $outputFull, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Log '[ERROR] 入力フォルダと出力フォルダが同一です。元ファイルを上書きする恐れがあるため別フォルダを指定してください。'
            return
        }
    } catch {
        Write-Log "[ERROR] パス解決に失敗: $($_.Exception.Message)"; return
    }

    # --- Create output folder ---
    if (Test-Path -LiteralPath $outputDir -PathType Leaf) {
        Write-Log "[ERROR] 出力先に同名のファイルが存在します: $outputDir"
        return
    }
    if (-not (Test-Path -LiteralPath $outputDir -PathType Container)) {
        try {
            [IO.Directory]::CreateDirectory($outputDir) | Out-Null
            Write-Log "[INFO ] 出力フォルダを作成しました: $outputDir"
        } catch {
            Write-Log "[ERROR] 出力フォルダを作成できません: $outputDir"
            Write-Log "        $($_.Exception.Message)"
            return
        }
    }

    if (-not $TargetFiles -or $TargetFiles.Count -eq 0) {
        Write-Log '[INFO ] 対象ファイルがありません。'; return
    }

    Write-Log "[INFO ] 入力 : $inputDir"
    Write-Log "[INFO ] 出力 : $outputDir"
    Write-Log "[INFO ] 設定 : ${maxW}x${maxH}  品質=$quality  形式=$format"
    Write-Log "[INFO ] 既存ファイル方針: $($cmbCollisionPolicy.SelectedItem)"
    Write-Log "[INFO ] 容量増加時: $($cmbLargerOutput.SelectedItem)"
    Write-Log "[INFO ] 対象ファイル: $($TargetFiles.Count) 件"
    Write-Log ''

    $encoder = Get-ImageEncoder -Format $format
    if (-not $encoder) {
        Write-Log "[ERROR] $format 用のエンコーダが見つかりません。"
        return
    }
    $ext = Get-OutputExtension -Format $format
    try {
        $outputPlan = New-ImageCompressorOutputPlan `
            -InputFiles $TargetFiles `
            -OutputDirectory $outputDir `
            -OutputExtension $ext `
            -CollisionPolicy $collisionPolicy
    } catch {
        Write-Log "[ERROR] 出力計画を作成できません: $($_.Exception.Message)"
        return
    }

    $ok = 0; $skip = 0; $fail = 0
    $totalOrigSize = 0L; $totalCompSize = 0L

    foreach ($plan in $outputPlan) {
        $f = $plan.InputFile
        $outName = $plan.OutputName
        $outPath = $plan.OutputPath
        Write-Log "[PROCESS] $($f.Name)"

        if ($plan.Reason -and $plan.Action -ne 'Skip') {
            Write-Log "[INFO ] $($plan.Reason)"
        }
        if ($plan.Action -eq 'Skip') {
            Write-Log "[SKIP  ] $($f.Name) -- $($plan.Reason): $outName"
            $skip++
            $script:progressCurrent++
            Update-Progress -Current $script:progressCurrent -Total $script:progressTotal
            continue
        }

        $allowReplace = $plan.Action -eq 'Overwrite'
        if ($plan.Action -eq 'Confirm' -and [IO.File]::Exists($outPath)) {
            $choice = [System.Windows.Forms.MessageBox]::Show(
                "既存ファイルを上書きしますか？`r`n$outPath",
                '上書き確認',
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
                Write-Log "[SKIP  ] $($f.Name) -- 利用者が上書きを拒否: $outName"
                $skip++
                $script:progressCurrent++
                Update-Progress -Current $script:progressCurrent -Total $script:progressTotal
                continue
            }
            $allowReplace = $true
        }

        $img = $null
        $bmp = $null
        $g   = $null
        $ep  = $null
        try {
            $img = [System.Drawing.Image]::FromFile($f.FullName)
            Fix-ExifOrientation -Image $img

            # Resize calculation (at least 1 x 1)
            $dimensions = Get-ImageCompressorResizeDimensions `
                -Width $img.Width `
                -Height $img.Height `
                -MaxWidth $maxW `
                -MaxHeight $maxH
            $newW = $dimensions.Width
            $newH = $dimensions.Height

            # Create bitmap. JPEG has no alpha channel, so compose it onto
            # the explicitly selected background color.
            $pixelFormat = if ($format -eq 'JPEG') {
                [System.Drawing.Imaging.PixelFormat]::Format24bppRgb
            } else {
                [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb
            }
            $bmp = New-Object System.Drawing.Bitmap(
                $newW,
                $newH,
                $pixelFormat)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            if ($format -eq 'JPEG') {
                $g.Clear((Get-JpegBackgroundColor))
            } else {
                $g.Clear([System.Drawing.Color]::Transparent)
            }
            $g.CompositingQuality = 'HighQuality'
            $g.InterpolationMode = 'HighQualityBicubic'
            $g.SmoothingMode = 'HighQuality'
            $g.PixelOffsetMode = 'HighQuality'
            $g.DrawImage($img, 0, 0, $newW, $newH)
            $g.Dispose()
            $g = $null

            # Copy EXIF（Orientation タグは物理回転済みのためスキップして二重適用を防止）
            try {
                foreach ($pi in $img.PropertyItems) {
                    if ($pi.Id -eq $ExifOrientationTagId) { continue }
                    $bmp.SetPropertyItem($pi)
                }
            } catch {
                Write-Log "[WARN ] EXIF コピー失敗: $($_.Exception.Message)"
            }

            # JPEG のみ Quality を適用、PNG/BMP は EncoderParameters 無し
            if ($format -eq 'JPEG') {
                $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
                $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
                    [System.Drawing.Imaging.Encoder]::Quality, [long]$quality
                )
            }

            $origSize = $f.Length
            $saveResult = Save-ImageSafely `
                -Bitmap $bmp `
                -Encoder $encoder `
                -EncoderParameters $ep `
                -FinalPath $outPath `
                -AllowReplace $allowReplace `
                -OriginalBytes $origSize `
                -LargerOutputPolicy $largerOutputPolicy
            $sizeChange = Format-ImageCompressorSizeChange `
                -OriginalBytes $origSize `
                -OutputBytes $saveResult.OutputBytes

            if (-not $saveResult.Saved) {
                Write-Log "[SKIP  ] $($f.Name) -- 元より大きくなるため保存しません ($(Format-FileSize $origSize) -> $(Format-FileSize $saveResult.OutputBytes), $sizeChange)"
                $skip++
            } else {
                $compSize = $saveResult.OutputBytes
                $totalOrigSize += $origSize
                $totalCompSize += $compSize
                if ($saveResult.IsLarger -and $largerOutputPolicy -eq 'Warn') {
                    Write-Log "[WARN ] 出力サイズが元画像より増加しました: $outName"
                }
                Write-Log "[  OK  ] $($f.Name) -> $outName  ${newW}x${newH}  $(Format-FileSize $origSize) -> $(Format-FileSize $compSize) ($sizeChange)"
                $ok++
            }
        } catch {
            Write-Log "[FAIL  ] $($f.Name) -- $($_.Exception.Message)"
            $fail++
        } finally {
            if ($g)   { $g.Dispose() }
            if ($ep)  { $ep.Dispose() }
            if ($bmp) { $bmp.Dispose() }
            if ($img) { $img.Dispose() }
        }

        $script:progressCurrent++
        Update-Progress -Current $script:progressCurrent -Total $script:progressTotal
    }

    Write-Log ''
    Write-Log '============================================'
    Write-Log "[SUMMARY] 成功=$ok  スキップ=$skip  失敗=$fail"
    if ($totalOrigSize -gt 0) {
        $totalChange = Format-ImageCompressorSizeChange `
            -OriginalBytes $totalOrigSize `
            -OutputBytes $totalCompSize
        Write-Log "[SUMMARY] 合計: $(Format-FileSize $totalOrigSize) -> $(Format-FileSize $totalCompSize) ($totalChange)"
    }
    Write-Log "[INFO ] 出力フォルダ: $outputDir"
    if ($fail -gt 0) {
        Write-Log "[WARN ] $fail 件のファイル処理に失敗しました。"
    }
}

# === Event handlers ===

# --- Scan button ---
$btnScanFiles.Add_Click({ Update-FileList })

# --- Input folder change: invalidate scan ---
$txtInput.Add_TextChanged({
    $dgv.Rows.Clear()
    $lblSummary.Text = '入力フォルダが変更されました。[確認] を押してください'
    $script:scanValid = $false
    $script:cachedFiles = @()
})

# --- Execute button ---
$btnRun.Add_Click({
    $dgv.EndEdit()
    $txtLog.Clear()
    Reset-Progress

    if (-not $script:scanValid -or $dgv.Rows.Count -eq 0) {
        Write-Log '[INFO ] 一覧が未確認状態です。自動スキャンを実行します...'
        Update-FileList
        if (-not $script:scanValid) { return }
    }

    # Collect checked files from grid
    $targetFiles = @()
    foreach ($row in $dgv.Rows) {
        $idx = $row.Index
        if ($idx -ge $script:cachedFiles.Count) { continue }
        if ($row.Cells['Target'].Value -eq $true) {
            $targetFiles += $script:cachedFiles[$idx]
        }
    }

    if ($targetFiles.Count -eq 0) {
        Write-Log '[ERROR] チェックされたファイルがありません。対象列にチェックを入れてください。'
        return
    }

    $multiFrameWarnings = @(Get-MultiFrameWarnings -Files $targetFiles)
    if ($multiFrameWarnings.Count -gt 0) {
        $warningDetails = ($multiFrameWarnings | Select-Object -First 10) -join "`r`n"
        if ($multiFrameWarnings.Count -gt 10) {
            $warningDetails += "`r`nほか $($multiFrameWarnings.Count - 10) 件"
        }
        $choice = [System.Windows.Forms.MessageBox]::Show(
            "複数フレーム/ページの画像があります。`r`n先頭フレーム/ページだけを静止画として保存します。`r`n`r`n$warningDetails`r`n`r`n続行しますか？",
            '複数フレーム/ページの確認',
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($choice -ne [System.Windows.Forms.DialogResult]::Yes) {
            Write-Log '[INFO ] 複数フレーム/ページ画像の確認で処理を中止しました。'
            return
        }
    }

    $script:progressCurrent = 0
    $script:progressTotal = $targetFiles.Count
    Update-Progress -Current 0 -Total $script:progressTotal

    Set-UIEnabled $false
    try {
        Invoke-Compress -TargetFiles $targetFiles
    } finally {
        Set-UIEnabled $true
    }
})

# === Show ===
if (-not $NoGui) {
    [void]$form.ShowDialog()
    exit 0
}
