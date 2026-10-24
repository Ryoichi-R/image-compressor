# Image Compressor

## 概要

Image Compressorは、Windows向けの画像一括縮小・圧縮アプリです。画像と設定は利用者のPC内で処理し、現行versionには外部送信、telemetry、account、自動update機能はありません。

## 動作要件

- Windows 10／11
- x64またはARM64
- Windows PowerShell 5.1
- インストール先への書き込み権限

.NET Runtimeはアプリへ同梱されています。.NET SDK、コンパイラー、管理者権限、レジストリ登録、PATH変更、Windowsサービス登録は不要です。

## インストール

[Release 1.0.14](https://github.com/Ryoichi-R/image-compressor/releases/tag/v1.0.14)でinstaller（x64/ARM64同梱）とportable x64を提供します。検証済み範囲・既知の制限・SHA-256はRelease説明を確認してください。ARM64のportable起動にはinstaller ZIP内のinstaller/payload/ImageCompressor-win-arm64.zipを新しいフォルダーへ展開して使用できます。

[GitHub Releases](https://github.com/Ryoichi-R/image-compressor/releases)から
`image-compressor-installer.zip`をダウンロードして展開し、展開先直下の
**「ここから開始 - Image Compressorを導入・更新.bat」** をダブルクリックしてください。
source repositoryには自己完結payloadを含めないため、source checkout直下のBATは
そのままではインストール用配布物として動作しません。

- 引数なし: インストール先の親フォルダーを画面で選択
- フォルダーをBATへドラッグ＆ドロップ: そのフォルダーを親として使用
- 同じBATを再実行: 既存インストールを安全に更新

選択した親フォルダーの下へ`Image Compressor`専用フォルダーを作成します。成功後もアプリは自動起動しません。開かれたインストール先にある`ImageCompressor.App.exe`を起動してください。

## 使用方法

入力画像またはフォルダーを画面へ追加し、対象、最大寸法、出力形式、品質、保存先を選んで処理を開始します。入力はJPEG、PNG、BMP、GIF、TIFF、出力はJPEG、PNG、BMPに対応します。

指定容量以下へのJPEG圧縮、安全保存、階層維持、重複時の連番・skip・overwrite・confirm、進捗表示、キャンセルを利用できます。詳しい機能は[project README](project/README.md)を参照してください。

## 設定

設定はportable構成ではEXEと同じフォルダーの`settings.json`へ保存します。portable設定がない場合は`%LOCALAPPDATA%\ImageCompressor\settings.json`を使用します。更新時に`settings.json`と利用者が追加したファイルは変更しません。

## アンインストール

1. Image Compressorを終了します。
2. 必要なら`settings.json`を別の場所へバックアップします。
3. インストール先の`Image Compressor`フォルダーを削除します。
4. 更新用バックアップも不要なら`%LOCALAPPDATA%\ImageCompressorInstaller\Backups`を削除します。

レジストリ、PATH、サービスには登録しないため、追加のアンインストーラー操作はありません。

## 既知の制限

- Windows専用です。macOS／Linux GUIはsupport対象外です。
- WebP、HEIC、AVIFは未対応です。
- 複数フレームGIF／TIFFは既定で先頭フレームだけを出力し、logへ警告します。
- version1.0.14はWindows11 x64／ARM64で実機確認済みです。動的DPI切替後のチェック記号縮小、100%復帰後のボタン帯差、未確認の導入条件・応答時間は[Release説明](https://github.com/Ryoichi-R/image-compressor/releases/tag/v1.0.14)に記載しています。Windows10は今回実機未確認です。
- 現在の配布binaryはcode signing未実施です。

## Privacy・security・公開範囲

- 外部送信とローカル保存の説明: [PRIVACY.md](PRIVACY.md)
- 脆弱性の非公開報告方針: [SECURITY.md](SECURITY.md)
- sourceとRelease assetの境界: [PUBLICATION.md](PUBLICATION.md)
- 第三者softwareの通知: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)

## ライセンス

Image Compressor本体は[MIT License](LICENSE)で提供します。同梱.NET Runtimeのライセンスと第三者通知は、installer payloadへ含めるbuild契約にしています。詳細は[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)を参照してください。

## 開発

アプリ実装、テスト、ビルド、配布用成果物などの開発者向けファイルは[project](project/)にまとめています。build・test手順は[project README](project/README.md)、導入・更新の詳細は[installer README](project/installer/README.md)を参照してください。
