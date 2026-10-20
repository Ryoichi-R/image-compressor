# Image Compressor baselines

このソース公開ではfixture画像と測定結果JSONを同梱しません。以下は過去の測定記録・手順であり、この公開候補の再測定結果や現行の品質保証を表すものではありません。再測定には別途fixtureを用意してください。

測定日時は2026-07-29（Asia/Tokyo）。`fixture-v2`は個人情報を含まないPNG 1,000枚で、fixture SHA-256は `BA44A4D98F299DE10C8ED63EECF8EEE3FB4B32A452B555AE8B88C4E526527631`。

`fixture-v2`の`v2`はfixture content versionであり、`phase2-csharp-v1.json`等の`v1`はreport revisionである。両者を同じversion軸として扱わない。report更新時は`schemaVersion`、measurement revision、fixture content version、fixture SHA-256を別々に記録する。旧`fixture-v1`は履歴資産であり、自動削除しない。

解像度は2560×1440を10枚、1440×2560を10枚、1600×1200を80枚、800×600を300枚、320×240を600枚とした。各画像には決定的に生成した24本の線を描き、先頭100枚では最大1920×1080への縮小が実際に発生する。指定容量モードは100 KiBで測定した。

## 正本

- `legacy-powershell-v1.json`: 現行PowerShellアプリを`-NoGui`で読み込み、`Invoke-Compress`のRun→summary相当区間を3回測定。
- `phase2-csharp-v1.json`: C# conventional mode、3回median。
- `phase3-target-size-v1.json`: C# target-size mode、3回median。
- `engine-decision-v1.json`: engine依存値と採用閾値。
- `gate-summary-v1.json`: 比較結果。
- `spike-publish-v1.json`: spike harnessのself-contained実行確認。

`_internal/spike/ImageCompressor.SpikeHarness`は`ImageCompressor.slnx`の`/tools/`に含まれる計測契約であり、通常buildのwarnings-as-errors対象である。Domain／Infrastructure／Appを参照してproduction処理を呼び出す一方、UI操作とinstaller経路は含まない。この等価範囲と差分を再測定receiptに明記する。

3つの測定JSONは同じhost hash、OS、architecture、processor count、fixture hashを保持する。raw machine nameは保存せずSHA-256先頭12桁だけを記録するため、同一host性を成果物から検証できる。

## 結果

- legacy実アプリ median: 22,126.4591 ms
- C# conventional median: 21,208.7343 ms（legacy比0.9585、PASS）
- C# target-size median: 53,892.3442 ms（conventional比2.541）
- target-size: 最大9試行、平均1.646試行（`N=64`、`A=2.0`、PASS）
- private bytes: 100枚checkpoint間で+5 MiB超が4回連続しないこと、終了後GC後が100枚目sample + max(128 MiB, 20%)以下であることを各runで確認（PASS）
- resource: handle delta最大3、GDI handle delta最大0（ともに+10以内、PASS）
- cancel: 本番`CancelRequestHandler`の`Cancel()`開始からlabel更新完了まで1,000回測定し、p95最大0.0098 ms。native encode復帰後から`Cancelled`結果まで最大0.7137 ms（250 ms／2,000 ms gateともにPASS）

## 再測定

測定出力は再生成可能なので、workspaceの`runs/`ではなく一時ディレクトリへ出す。

```powershell
$runRoot = Join-Path $env:TEMP 'image-compressor-baseline-v2'

pwsh -NoProfile -File image-compressor/project/scripts/measure-image-compressor-legacy-baseline.ps1 `
  -FixtureRoot image-compressor/project/_internal/baselines/fixture-v2 `
  -OutputRoot (Join-Path $runRoot 'legacy') `
  -ReportPath image-compressor/project/_internal/baselines/legacy-powershell-v1.json `
  -Count 1000 -Runs 3

dotnet run `
  --project image-compressor/project/_internal/spike/ImageCompressor.SpikeHarness/ImageCompressor.SpikeHarness.csproj `
  -c Release -- `
  --mode conventional `
  --input image-compressor/project/_internal/baselines/fixture-v2 `
  --output (Join-Path $runRoot 'csharp') `
  --report image-compressor/project/_internal/baselines/phase2-csharp-v1.json `
  --runs 3

dotnet run `
  --project image-compressor/project/_internal/spike/ImageCompressor.SpikeHarness/ImageCompressor.SpikeHarness.csproj `
  -c Release -- `
  --mode target `
  --input image-compressor/project/_internal/baselines/fixture-v2 `
  --output (Join-Path $runRoot 'target') `
  --report image-compressor/project/_internal/baselines/phase3-target-size-v1.json `
  --runs 3 --target-bytes 102400
```

`image-compressor/project/_internal/baselines/runs/`の`legacy`、`csharp`、`csharp-r2`、`csharp-r3`、`target`、`target-r2`、`target-r3`は旧測定時の再生成可能な出力であり、いずれも正本JSONの生成元ではない。削除はworkspaceの破壊操作ポリシーに従い、明示承認後に行う。
