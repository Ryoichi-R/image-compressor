# Image Compressor C# 版アーキテクチャ

現行マスタープラン: [image-compressor-master-plan.md](../../../plans/image-compressor-master-plan.md)  
移行時の履歴計画: [image-compressor-csharp-feature-expansion-plan.md](../../../plans/image-compressor-csharp-feature-expansion-plan.md)  
画像エンジン ADR: [ADR-008](adr/008-image-compressor-imaging-engine.md)

## 構造

- `ImageCompressor.Domain/Contracts`: request、result、preset、window placement契約。
- `ImageCompressor.Domain/Planning`: 出力計画、衝突方針、root逸脱防止。
- `ImageCompressor.Domain/Compression`: リサイズ、指定容量探索。
- `ImageCompressor.Infrastructure/Imaging`: `System.Drawing` encodeとOrientation補正。
- `ImageCompressor.Infrastructure/FileSystem`: 複数root scan、安全保存、orphan cleanup。
- `ImageCompressor.Infrastructure/Settings`: portable／LocalAppData設定。
- `ImageCompressor.Infrastructure/Compression`: 逐次jobとcancel。
- `ImageCompressor.App/Presenters`: WinForms UI、D&D、進捗、上書き確認。

PowerShell 版は移行期間中 `Core (PS)`、C# 版は `Domain/Core (.NET)` と表記する。既存 `.ps1`、`.psm1` はロールバック用として当面維持する。

配布候補は既存`installer/payload/`や`project/dist/`を直接更新せず、検証済みpayload backupを前提に一意なcandidate rootへ生成する。candidate receiptの`productVersion`、`buildId`、`sourceDigest`をsource／lockfile／artifact hashの結合キーとし、正規payloadへのpromotionは別の明示承認とする。

## 安全保存契約

出力と同じディレクトリーに `.image-compressor-v2-<instance-guid>-<operation-guid>.lease` を作り、同じ操作 ID の `.tmp` の書き込み、検証、確定、後始末まで保持する。入力は画像ごとに書き込み・削除共有を拒むハンドルで開き、実際の形式・フレーム数・容量の判定からコピーまたはエンコードの確定まで同じ入力を使う。既存出力を置換する前には、走査済み入力とのパスおよび Windows ファイル ID の照合を行う。

出力先の掃除では子 reparse point を辿らず、lease を取得できた場合だけ対応する一時ファイルを回収する。lease だけが残った場合は lease を回収する。旧形式および lease のない tmp は保持して警告する。ネットワーク上でも経過時間による削除は行わない。

通常のウィンドウ閉鎖と `ApplicationExitCall` はキャンセル要求後に処理結果の反映と UI の後始末を待つ。OS シャットダウンとタスクマネージャーによる終了要求では、キャンセルを通知して最大 250ms だけ worker を待つ。キャンセル後の未確定出力は保存確定を中止し、強制終了で残った一時ファイルは次回に回収する。

## 設定

EXE と同じディレクトリに `settings.json` が既に存在する場合は portable 設定として優先し、なければ `%LOCALAPPDATA%\ImageCompressor\settings.json` を使う。固定プリセット値はコードを正本とし、設定にはプリセット ID と変更された値だけを保存する。不正な項目は個別に既定値へ戻し、読めない形式や未対応の schema は既定設定で起動する。修復済み設定を保存する際は同じディレクトリーに元の bytes を退避し、退避できない原本は上書きしない。

画面位置は `Screen.AllScreens` の各作業領域と64px以上交差する場合だけ復元する。

## 現行機能インベントリ

| 現行機能／判断対象                          | 分類    | C# 基礎版の扱い                                                                            |
| ------------------------------------------- | ------- | ------------------------------------------------------------------------------------------ |
| 6プリセットと選択状態                       | Migrate | コード定義を正本とし、選択IDとoverrideのみ保存                                             |
| `.jpg/.jpeg/.png/.bmp/.gif/.tiff/.tif` 入力 | Migrate | 同じ拡張子をscanし、破損画像は理由付きSkipped                                              |
| 最大寸法、品質、JPEG/PNG/BMP出力            | Migrate | 最小1px、縦横比維持                                                                        |
| EXIF Orientation 1～8                       | Migrate | 回転・反転後にOrientationと入力EXIFを除去                                                  |
| 容量増加 `Skip/Warn/Save`                   | Migrate | 3値を維持                                                                                  |
| 入力／出力欄、参照button                    | Migrate | 複数入力はD&Dで追加し表示                                                                  |
| gridの対象checkbox、拡張子、寸法列          | Migrate | 対象選択とSkipped理由を表示                                                                |
| 対象件数、合計容量、進捗率                  | Migrate | KiBと百分率で表示                                                                          |
| ログpane                                    | Migrate | job結果、cancel UI応答、警告を表示                                                         |
| 実行中の設定固定                            | Migrate | 入出力、preset、寸法、品質、形式、衝突、grid、D&Dを固定                                    |
| 実行中Close                                 | Migrate | 確認後にcancelし、job停止完了まで待機                                                      |
| `.bat`の通常／`min`起動                     | Migrate | C#版へ`min`を追加せず実引数だけを渡し、legacy fallbackのPowerShell consoleだけを最小化する |
| 自動連番と衝突方針                          | Migrate | `_001`、Skip、Overwrite、Confirm                                                           |
| 一時保存→検証→rename/replace                | Migrate | 同一directoryの自社prefix tempを使用                                                       |
| JPEG透明背景                                | Migrate | 白／黒を明示選択                                                                           |
| 複数フレーム警告                            | Migrate | 先頭frameまたは理由付きSkip                                                                |
| 指定容量探索                                | Migrate | memory candidate、memoize、局所sweep、確定候補だけ保存                                     |
| 指定容量＋PNG/BMP選択                       | Migrate | JPEGへ変換／保存しないを明示選択                                                           |
| D&D                                         | Migrate | 複数file／folder、複数root prefix、実行中拒否                                              |
| 設定保存                                    | Migrate | schema検証、portable優先、preset fallback                                                  |
| PowerShell GUIを既定runtimeとして維持       | Retire  | C# cutover後30日のgateと明示承認後に撤去判断（IC-8）                                       |
| PowerShell module／script rollback資産      | Defer   | rollback ZIPとともに保持期限後も自動削除しない                                             |
| GPS/EXIF削除UI                              | Defer   | IC-1                                                                                       |
| preview                                     | Defer   | IC-2                                                                                       |
| 減色PNG                                     | Defer   | IC-3                                                                                       |
| 並列処理                                    | Defer   | IC-4                                                                                       |
| installer                                   | Defer   | IC-5                                                                                       |
| code signing                                | Defer   | IC-6                                                                                       |
| WebP/HEIC/AVIF                              | Defer   | 追加依存と再配布gate後のIC-7                                                               |
