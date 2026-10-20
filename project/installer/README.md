# Image Compressor 導入・更新パッケージ

この文書の手順は、GitHub Releaseの`image-compressor-installer.zip`を展開した配布フォルダーを対象とします。source repositoryには生成済みpayloadを含めないため、source checkout直下のBATだけではインストールできません。

## 必要条件

- Windows 10／11
- x64またはARM64
- Windows PowerShell 5.1
- インストール先への書き込み権限

.NETランタイムはアプリへ同梱されています。.NET SDK、コンパイラー、管理者権限、レジストリ登録、PATH変更、Windowsサービス登録は不要です。

## インストール／更新

1. `ここから開始 - Image Compressorを導入・更新.bat`をダブルクリックします。
2. 表示された画面でインストール先の親フォルダーを選びます。
3. 選択先に`Image Compressor`フォルダーが作成されます。
4. 完了後に開かれたフォルダー内の`ImageCompressor.App.exe`を起動します。導入処理がアプリを自動起動することはありません。

BATへ親フォルダーをドラッグ＆ドロップするか、コマンドラインから1個のフォルダーパスを渡すこともできます。同じBATを再実行すると更新になります。

更新時は、アプリを終了してください。起動中の場合は何も更新せず終了方法を表示します。新しいアプリはOS一時領域で展開・SHA-256・PE architecture検証を行い、現在の正常な一式を1世代バックアップしてから反映します。反映に失敗した場合は自動復旧します。

`settings.json`と、利用者がインストールフォルダーへ追加したファイルは更新対象外です。

## アンインストール

1. Image Compressorを終了します。
2. 必要なら`settings.json`を別の場所へバックアップします。
3. インストール先の`Image Compressor`フォルダーを削除します。
4. 更新用バックアップも不要なら、`%LOCALAPPDATA%\ImageCompressorInstaller\Backups`を削除します。

レジストリ、PATH、サービスには何も登録しないため、追加のアンインストーラー操作はありません。

## トラブル時

- 終了コード3: フォルダー選択がキャンセルされました。
- 「running from the update target」: `ImageCompressor.App.exe`を終了してから再実行してください。
- payload／SHA-256／architectureエラー: 配布フォルダーが欠損または破損しています。配布物を再取得してください。
- 更新失敗: 画面に表示された原因と終了コードを確認してください。更新前の正常な一式は自動復旧されます。
