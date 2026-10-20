[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$FixtureRoot,
    [Parameter(Mandatory)][string]$OutputRoot,
    [Parameter(Mandatory)][string]$ReportPath,
    [ValidateRange(1, 100000)][int]$Count = 1000,
    [ValidateRange(1, 20)][int]$Runs = 3
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not ('ImageCompressorBaseline.NativeMethods' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ImageCompressorBaseline {
    public static class NativeMethods {
        [DllImport("user32.dll")]
        public static extern int GetGuiResources(IntPtr process, int flags);
    }
}
'@
}

$fixtureFull = [IO.Path]::GetFullPath($FixtureRoot)
$outputFull = [IO.Path]::GetFullPath($OutputRoot)
$reportFull = [IO.Path]::GetFullPath($ReportPath)
[IO.Directory]::CreateDirectory($fixtureFull) | Out-Null
[IO.Directory]::CreateDirectory($outputFull) | Out-Null
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($reportFull)) | Out-Null

$existing = @(Get-ChildItem -LiteralPath $fixtureFull -Filter '*.png' -File)
if ($existing.Count -ne $Count) {
    if ($existing.Count -gt 0) {
        throw "fixture件数が要求と不一致です。既存=$($existing.Count), 要求=$Count"
    }

    for ($index = 0; $index -lt $Count; $index++) {
        $size = if ($index -lt 10) {
            @(2560, 1440)
        } elseif ($index -lt 20) {
            @(1440, 2560)
        } elseif ($index -lt 100) {
            @(1600, 1200)
        } elseif ($index -lt 400) {
            @(800, 600)
        } else {
            @(320, 240)
        }
        $bitmap = [Drawing.Bitmap]::new($size[0], $size[1])
        try {
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            try {
                $color = [Drawing.Color]::FromArgb(
                    255,
                    ($index * 37) % 256,
                    ($index * 67) % 256,
                    ($index * 97) % 256)
                $graphics.Clear($color)
                for ($line = 0; $line -lt 24; $line++) {
                    $lineColor = [Drawing.Color]::FromArgb(
                        255,
                        ($index * 11 + $line * 29) % 256,
                        ($index * 17 + $line * 43) % 256,
                        ($index * 23 + $line * 59) % 256)
                    $pen = [Drawing.Pen]::new($lineColor, 1 + ($line % 3))
                    try {
                        $graphics.DrawLine(
                            $pen,
                            0,
                            ($index * 7 + $line * 31) % $size[1],
                            $size[0] - 1,
                            ($index * 13 + $line * 47) % $size[1])
                    } finally {
                        $pen.Dispose()
                    }
                }
            } finally {
                $graphics.Dispose()
            }
            $path = Join-Path $fixtureFull ('fixture-{0:D4}.png' -f $index)
            $bitmap.Save($path, [Drawing.Imaging.ImageFormat]::Png)
        } finally {
            $bitmap.Dispose()
        }
    }
}

$files = @(Get-ChildItem -LiteralPath $fixtureFull -Filter '*.png' -File | Sort-Object Name)
$sha = [Security.Cryptography.IncrementalHash]::CreateHash(
    [Security.Cryptography.HashAlgorithmName]::SHA256)
try {
    foreach ($file in $files) {
        $relative = [Text.Encoding]::UTF8.GetBytes($file.Name)
        $sha.AppendData($relative)
        $sha.AppendData([IO.File]::ReadAllBytes($file.FullName))
    }
    $fixtureHash = [Convert]::ToHexString($sha.GetHashAndReset())
} finally {
    $sha.Dispose()
}

. (Join-Path $PSScriptRoot '..\image-compressor.ps1') -NoGui
$measurements = [Collections.Generic.List[object]]::new()
$process = [Diagnostics.Process]::GetCurrentProcess()

for ($run = 1; $run -le $Runs; $run++) {
    $runOutput = Join-Path $outputFull ('run-{0:D2}' -f $run)
    [IO.Directory]::CreateDirectory($runOutput) | Out-Null
    $process.Refresh()
    $privateBefore = $process.PrivateMemorySize64
    $handlesBefore = $process.HandleCount
    $gdiBefore = [ImageCompressorBaseline.NativeMethods]::GetGuiResources($process.Handle, 0)
    $txtInput.Text = $fixtureFull
    $txtOutput.Text = $runOutput
    $numMaxW.Value = 1920
    $numMaxH.Value = 1080
    $numQuality.Value = 75
    $cmbFormat.SelectedItem = 'JPEG'
    $cmbCollisionPolicy.SelectedItem = '自動連番（推奨）'
    $cmbLargerOutput.SelectedItem = '常に保存'
    $cmbJpegBackground.SelectedItem = '白'
    $script:progressCurrent = 0
    $script:progressTotal = $files.Count
    Update-Progress -Current 0 -Total $script:progressTotal
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    Invoke-Compress -TargetFiles $files
    $stopwatch.Stop()
    $process.Refresh()
    $measurements.Add([ordered]@{
            run                = $run
            elapsedMilliseconds = $stopwatch.Elapsed.TotalMilliseconds
            privateBytesBefore = $privateBefore
            privateBytesAfter  = $process.PrivateMemorySize64
            handlesBefore      = $handlesBefore
            handlesAfter       = $process.HandleCount
            gdiHandlesBefore   = $gdiBefore
            gdiHandlesAfter    = [ImageCompressorBaseline.NativeMethods]::GetGuiResources(
                $process.Handle,
                0)
            succeeded          = $files.Count
            failed             = 0
        })
}

$orderedTimes = @($measurements.elapsedMilliseconds | Sort-Object)
$median = if ($orderedTimes.Count % 2 -eq 1) {
    $orderedTimes[[int][Math]::Floor($orderedTimes.Count / 2)]
} else {
    ($orderedTimes[($orderedTimes.Count / 2) - 1] +
        $orderedTimes[$orderedTimes.Count / 2]) / 2
}
$report = [ordered]@{
    schemaVersion = 1
    engine = 'legacy-powershell-system-drawing'
    measuredAt = [DateTimeOffset]::Now.ToString('o')
    host = [ordered]@{
        machine = 'host-{0}' -f ([Convert]::ToHexString(
                [Security.Cryptography.SHA256]::HashData(
                    [Text.Encoding]::UTF8.GetBytes([Environment]::MachineName))).Substring(0, 12))
        os = [Environment]::OSVersion.VersionString
        framework = [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
        architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
        processorCount = [Environment]::ProcessorCount
    }
    fixture = [ordered]@{
        root = [IO.Path]::GetFileName(
            $fixtureFull.TrimEnd([IO.Path]::DirectorySeparatorChar))
        count = $files.Count
        sha256 = $fixtureHash
    }
    settings = [ordered]@{
        mode = 'conventional'
        maxWidth = 1920
        maxHeight = 1080
        quality = 75
    }
    runs = $measurements
    medianMilliseconds = $median
    privateBytesMonotonicIncrease = @($measurements | Where-Object {
            $_.privateBytesAfter -le $_.privateBytesBefore
        }).Count -eq 0
    maximumPrivateBytesDelta = ($measurements | ForEach-Object {
            $_.privateBytesAfter - $_.privateBytesBefore
        } | Measure-Object -Maximum).Maximum
    maximumHandleDelta = ($measurements | ForEach-Object {
            $_.handlesAfter - $_.handlesBefore
        } | Measure-Object -Maximum).Maximum
    maximumGdiHandleDelta = ($measurements | ForEach-Object {
            $_.gdiHandlesAfter - $_.gdiHandlesBefore
        } | Measure-Object -Maximum).Maximum
}
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportFull -Encoding utf8
$report | ConvertTo-Json -Depth 8
