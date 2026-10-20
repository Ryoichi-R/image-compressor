# ADR-008: Image Compressor の基礎画像エンジン

- Status: Accepted
- Date: 2026-07-29

## Context

現行版は Windows PowerShell 5.1 と GDI+ (`System.Drawing`) を使用する。C# 移行では、JPEG/PNG/BMP/GIF/TIFF 入力、指定容量探索、EXIF Orientation 補正を維持しつつ、新しい本番依存を増やさない基礎リリースが必要である。

## Decision

基礎リリースは .NET 10 / win-x64 / `System.Drawing.Common` 相当の Windows Desktop Framework を使用する。NuGet の新規本番依存は追加しない。

同等性は出力寸法、向き、命名・連番、衝突分岐、安全保存 invariant、容量増加分岐という契約で判定する。出力バイト数、画素値、圧縮率の完全一致は要求しない。

16-bit TIFF は基礎版で 8-bit 出力となる。複数フレーム GIF/TIFF は既定で先頭フレームのみ出力し、警告を残す。

## Consequences

- WebP/HEIC/AVIF は基礎版では入力・出力とも無効である。
- HEIC/AVIF が必要になった場合だけ、ライセンス、delegate、再配布可否、HEVC 特許リスクを別ゲートで確認して Magick.NET 等を検討する。
- HEIC 出力 capability があっても、再配布条件を独立確認できるまでは既定 OFF とする。

## Phase 1 measured contract

2026-07-29の固定1,000枚fixtureで、1×1 JPEGの最小観測値は629 bytesだった。UI／Domain下限は余裕を持たせて1,024 bytes、最低品質10、最大試行数64、平均試行数gate 2.0、最小寸法1px、局所sweep 3、寸法縮小係数0.85を採用した。

C# conventional modeの3回medianは4,038.7336 ms、legacyは4,117.3081 msだった。target-sizeは最大9試行、平均1.228試行。詳細は [`_internal/baselines`](../../_internal/baselines/README.md) を正本とする。
