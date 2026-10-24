# Standalone build-tool policy. Keep these patterns aligned with the workspace
# secret-patterns contract; no workspace helper is required at product runtime.
function Test-SecretFilePath {
    param([Parameter(Mandatory)][string]$FilePath)
    $patterns = @('^\.env$', '^\.env\.', '^secrets\.', '\.key$', '\.pem$', '\.pfx$', '\.p12$', '^credentials\.')
    $path = [IO.Path]::GetFullPath($FilePath)
    while (-not [string]::IsNullOrWhiteSpace($path)) {
        $leaf = [IO.Path]::GetFileName($path.TrimEnd('\', '/')).Split(':')[0]
        foreach ($pattern in $patterns) {
            if ($leaf -match $pattern) { return $true }
        }
        $parent = [IO.Path]::GetDirectoryName($path)
        if ($parent -eq $path) { break }
        $path = $parent
    }
    return $false
}

function Assert-SafeFilePath {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-SecretFilePath -FilePath $Path) { throw 'SECRET_PATH_REJECTED' }
    $ancestor = [IO.Path]::GetFullPath($Path)
    while (-not [string]::IsNullOrWhiteSpace($ancestor)) {
        if (Test-Path -LiteralPath $ancestor) {
            if ((Get-Item -LiteralPath $ancestor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'REPARSE_PATH_REJECTED'
            }
        }
        $parent = [IO.Path]::GetDirectoryName($ancestor)
        if ($parent -eq $ancestor) { break }
        $ancestor = $parent
    }
}

function Assert-SafeFileTree {
    param([Parameter(Mandatory)][string]$Path)
    Assert-SafeFilePath -Path $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    # Walk metadata one directory at a time; reject links before traversing them.
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push([IO.Path]::GetFullPath($Path))
    while ($pending.Count -gt 0) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
            Assert-SafeFilePath -Path $item.FullName
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
}
