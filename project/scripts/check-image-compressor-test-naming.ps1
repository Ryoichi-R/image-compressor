[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_secret-path-guard.ps1')
$roots = @(
    (Join-Path $PSScriptRoot '..\tests\unit\image-compressor-dotnet'),
    (Join-Path $PSScriptRoot '..\tests\integration\image-compressor-dotnet')
)
$violations = foreach ($root in $roots) {
    if (-not (Test-Path -LiteralPath $root)) {
        continue
    }

    Assert-SafeFilePath -Path $root
    foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -Filter '*.cs' -File) {
        if (Test-SecretFilePath -FilePath $file.FullName) { throw 'SECRET_PATH_REJECTED' }
        Assert-SafeFilePath -Path $file.FullName
        $content = Get-Content -LiteralPath $file.FullName -Raw
        if ($content -match '\[(Fact|Theory)(?:Attribute)?(?:\(|\])' -and
            -not $file.Name.EndsWith('_spec.cs', [StringComparison]::OrdinalIgnoreCase)) {
            $file.FullName
        }
    }
}

if ($violations.Count -gt 0) {
    $violations | ForEach-Object { Write-Error "[TEST-NAMING] テストファイルは *_spec.cs: $_" }
    exit 1
}

Write-Host '[TEST-NAMING] PASS'
