Describe 'Image Compressor launcher' {
    BeforeAll {
        $script:launcherPath = Join-Path $PSScriptRoot '..\..\..\image-compressor.bat'
    }

    It '通常起動でminを追加せず実引数だけをEXEへ渡す' {
        $probe = Join-Path $TestDrive 'probe.cmd'
        $output = Join-Path $TestDrive 'args.txt'
        @'
@echo off
> "%IMAGE_COMPRESSOR_PROBE_OUTPUT%" echo LAUNCH_ARGS=[%*]
'@ | Set-Content -LiteralPath $probe -Encoding ascii

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = 'cmd.exe'
        $startInfo.UseShellExecute = $false
        $startInfo.ArgumentList.Add('/d')
        $startInfo.ArgumentList.Add('/c')
        $startInfo.ArgumentList.Add('call')
        $startInfo.ArgumentList.Add($script:launcherPath)
        $startInfo.ArgumentList.Add('C:\tmp\photo.png')
        $startInfo.ArgumentList.Add('two words.png')
        $startInfo.Environment['IMAGE_COMPRESSOR_TEST_PROBE'] = $probe
        $startInfo.Environment['IMAGE_COMPRESSOR_PROBE_OUTPUT'] = $output
        $process = [Diagnostics.Process]::Start($startInfo)
        $process.WaitForExit()

        $process.ExitCode | Should -Be 0
        (Get-Content -LiteralPath $output -Raw).Trim() |
            Should -Be 'LAUNCH_ARGS=[C:\tmp\photo.png "two words.png"]'
    }

    It 'fallbackをNoProfileかつ最小化で起動する' {
        $launcher = Get-Content -LiteralPath $script:launcherPath -Raw
        $launcher | Should -Match 'start "" /min powershell\.exe -NoProfile -STA'
    }
}
