Set-StrictMode -Version Latest

function Get-ImageCompressorResizeDimensions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Width,
        [Parameter(Mandatory)][int]$Height,
        [Parameter(Mandatory)][int]$MaxWidth,
        [Parameter(Mandatory)][int]$MaxHeight
    )

    if ($Width -le 0 -or $Height -le 0) {
        throw '入力画像の幅と高さは1以上である必要があります。'
    }
    if ($MaxWidth -le 0 -or $MaxHeight -le 0) {
        throw '最大幅と最大高さは1以上である必要があります。'
    }

    $scale = [Math]::Min(
        [double]$MaxWidth / [double]$Width,
        [double]$MaxHeight / [double]$Height)
    if ($scale -gt 1) { $scale = 1 }

    return [pscustomobject]@{
        Width  = [Math]::Max(1, [int][Math]::Round($Width * $scale))
        Height = [Math]::Max(1, [int][Math]::Round($Height * $scale))
        Scale  = $scale
    }
}

function Format-ImageCompressorSizeChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][long]$OriginalBytes,
        [Parameter(Mandatory)][long]$OutputBytes
    )

    if ($OriginalBytes -le 0) {
        return '変化率を計算できません'
    }

    $percent = [Math]::Round(
        [Math]::Abs(($OutputBytes - $OriginalBytes) / [double]$OriginalBytes) * 100,
        1)
    if ($OutputBytes -lt $OriginalBytes) {
        return ('{0:N1}%削減' -f $percent)
    }
    if ($OutputBytes -gt $OriginalBytes) {
        return ('{0:N1}%増加' -f $percent)
    }
    return '変化なし'
}

function New-ImageCompressorOutputPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.FileInfo[]]$InputFiles,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [Parameter(Mandatory)][string]$OutputExtension,
        [Parameter(Mandatory)]
        [ValidateSet('AutoRename', 'Skip', 'Overwrite', 'Confirm')]
        [string]$CollisionPolicy
    )

    if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
        throw '出力フォルダが空です。'
    }
    if ([string]::IsNullOrWhiteSpace($OutputExtension)) {
        throw '出力拡張子が空です。'
    }
    if (-not $OutputExtension.StartsWith('.')) {
        $OutputExtension = ".$OutputExtension"
    }

    $outputFull = [IO.Path]::GetFullPath($OutputDirectory)
    $reserved = [Collections.Generic.HashSet[string]]::new(
        [StringComparer]::OrdinalIgnoreCase)
    $plans = [Collections.Generic.List[object]]::new()

    foreach ($inputFile in $InputFiles) {
        $baseName = [IO.Path]::GetFileNameWithoutExtension($inputFile.Name)
        $suffix = 0
        $candidatePath = $null
        $candidateName = $null

        while ($true) {
            $candidateName = if ($suffix -eq 0) {
                "$baseName$OutputExtension"
            } else {
                '{0}_{1:D3}{2}' -f $baseName, $suffix, $OutputExtension
            }
            $candidatePath = [IO.Path]::GetFullPath(
                (Join-Path $outputFull $candidateName))
            $reservedCollision = $reserved.Contains($candidatePath)
            $diskCollision = [IO.File]::Exists($candidatePath)

            if ($reservedCollision -or
                ($CollisionPolicy -eq 'AutoRename' -and $diskCollision)) {
                $suffix++
                continue
            }
            break
        }

        [void]$reserved.Add($candidatePath)
        $exists = [IO.File]::Exists($candidatePath)
        $action = 'Write'
        $reason = ''

        if ($suffix -gt 0) {
            $reason = "出力名衝突を回避して $candidateName を使用"
        }

        if ($exists) {
            switch ($CollisionPolicy) {
                'Skip' {
                    $action = 'Skip'
                    $reason = '既存ファイルのためスキップ'
                }
                'Overwrite' {
                    $action = 'Overwrite'
                    $reason = '既存ファイルを安全に置換'
                }
                'Confirm' {
                    $action = 'Confirm'
                    $reason = '上書き確認が必要'
                }
            }
        }

        $plans.Add([pscustomobject]@{
                InputFile     = $inputFile
                OutputName    = $candidateName
                OutputPath    = $candidatePath
                Action        = $action
                Reason        = $reason
                TargetExisted = $exists
            })
    }

    return $plans.ToArray()
}

Export-ModuleMember -Function @(
    'Get-ImageCompressorResizeDimensions',
    'Format-ImageCompressorSizeChange',
    'New-ImageCompressorOutputPlan'
)
