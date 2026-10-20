# Image Compressor

Windows向けの画像一括縮小・圧縮ツールです。この `project` フォルダーには、アプリ実装、テスト、ビルド、配布用成果物などの開発者向けファイルをまとめています。`image-compressor.bat` を起動すると、C# portable版を優先し、配布EXEがない場合だけ従来のPowerShell版へフォールバックします。

## 一般利用者向けの導入・更新

GitHub Releaseの`image-compressor-installer.zip`を展開し、配布フォルダー直下にある`ここから開始 - Image Compressorを導入・更新.bat`を使用します。引数なしでは親フォルダー選択画面を表示し、選択先の下へ`Image Compressor`専用フォルダーを作成します。BATへ親フォルダーをドラッグ＆ドロップするか、1個のフォルダーパスを引数にすることもできます。

同じBATが新規導入と更新を兼ねます。x64／ARM64を自動判定し、同梱済みの自己完結payloadを使用するため、利用者PCに.NET SDK、コンパイラー、PowerShell 7は不要です。管理者権限、レジストリ登録、PATH変更、サービス登録も行いません。

更新前にアプリを終了してください。新payloadはOS一時領域でSHA-256とPE architectureを検証し、現在の管理対象ファイルを1世代バックアップしてから反映します。失敗時は自動復旧します。`settings.json`と利用者が追加したファイルは更新しません。成功後はアプリを自動起動せず、インストール先を開いて`ImageCompressor.App.exe`を案内します。

公開sourceには`installer/payload/`の生成済みZIPとmanifestを含めません。clean source checkoutからのbuildは、一意なcandidate rootへinstaller folder、installer ZIP、portable x64 ZIP、manifest、receiptを生成します。maintainer workspaceに既存payloadがある場合は、検証済みbackup manifestを指定してからbuildします。公開payloadはローカルbuild pathを埋め込まないsymbolなしbuildです。candidateの正規payloadへのpromotionは別の明示承認が必要です。詳しい導入、更新、アンインストール、必要条件は[installer README](installer/README.md)を参照してください。

自己完結payloadには.NET Runtimeが含まれるため、candidate builderは`installer/assets/legal/`の.NETライセンスと第三者通知も各runtime ZIPへ含めます。これらはinstallerが管理するfileとしてmanifestでhash検証し、更新時も他のmanaged fileと同じ安全経路で置換します。

## 対応範囲

- 入力: JPEG、PNG、BMP、GIF、TIFF
- 出力: JPEG、PNG、BMP
- 最大寸法、品質、6プリセット、JPEG背景色
- 指定容量以下へのJPEG圧縮
- 自動連番、skip、overwrite、confirm
- 安全保存、サブフォルダ、階層維持
- 複数ファイル／フォルダD&D、対象checkbox、件数／容量summary
- 進捗率、キャンセル、処理中Close待機、設定保存

WebP、HEIC、AVIFは基礎版では対象外です。複数フレームGIF/TIFFは既定で先頭フレームだけを出力し、ログに警告します。

指定容量は KiB（1 KiB = 1024 bytes）で指定します。PNG／BMP選択時は「JPEGへ変換」または「保存しない」を選べます。既に容量・寸法内で、形式とmetadata方針も一致する画像は既定で再エンコードせずコピーします。

portable配布候補はcandidate root配下の`dist/image-compressor-portable-win-x64.zip`です。ZIPにはEXE横の`settings.json`とsanitize済み`settings.example.json`を含み、installer候補と同じ`buildId`／`sourceDigest`から生成します。

## 開発・検証

```powershell
Push-Location image-compressor/project
try {
  dotnet restore ImageCompressor.slnx --locked-mode --configfile NuGet.config
  dotnet build ImageCompressor.slnx -c Release --no-restore
  dotnet test ImageCompressor.slnx -c Release --no-build
  pwsh -NoProfile -File scripts/check-image-compressor-test-naming.ps1
}
finally {
  Pop-Location
}
```

性能・resource baselineと再測定手順は [`_internal/baselines/README.md`](_internal/baselines/README.md) を参照してください。

maintainer workspaceに既存payloadがある場合のbackup:

```powershell
pwsh -NoProfile -File image-compressor/project/scripts/backup-image-compressor-payload.ps1 `
  -DestinationRoot image-compressor/project/_internal/rollback/<timestamp>-payload-v<version>
```

clean source checkoutからの一般利用者向けcandidate package:

```powershell
pwsh -NoProfile -File image-compressor/project/scripts/build-image-compressor-installer-package.ps1 `
  -OutputRoot image-compressor/project/_internal/candidates/<candidate-id>
```

既存payloadがあるmaintainer workspaceでは、baseline検証を省略できません。

```powershell
pwsh -NoProfile -File image-compressor/project/scripts/build-image-compressor-installer-package.ps1 `
  -OutputRoot image-compressor/project/_internal/candidates/<candidate-id> `
  -PayloadBackupManifest image-compressor/project/_internal/rollback/<backup>/payload-backup-manifest.json
```

candidate builderは指定先が既に存在する場合に停止し、`installer/payload/`と`project/dist/`を変更しません。

公開sourceでは`project/dist/`、`installer/payload/`の生成済みZIPとmanifest、過去candidate、promotion履歴、payload backup、build cache、再生成可能なbaseline runを除外します。ワンクリック導入はpayloadを同梱したGitHub Release assetで提供します。詳しい境界は[`../PUBLICATION.md`](../PUBLICATION.md)を参照してください。
