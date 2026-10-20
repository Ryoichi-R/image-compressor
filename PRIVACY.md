# Privacy

Image Compressorは、選択された画像を利用者のWindows PC内で処理するローカルアプリです。現行sourceには、画像、設定、利用状況を外部へ送信する通信処理、telemetry、analytics、account機能、自動update機能はありません。

## ローカルで扱う情報

- 利用者が選択した入力画像とそのfile path
- 利用者が指定した出力先と生成画像
- 圧縮・resize・出力形式などの設定
- 処理結果とerrorを表示する画面内log

source画像は上書きせず、指定した出力先へ新しいfileを保存します。画面内logはアプリが動作している間の表示用であり、現行実装は外部送信しません。

## 保存場所

- portable設定がある場合: `ImageCompressor.App.exe`と同じfolderの`settings.json`
- portable設定がない場合: `%LOCALAPPDATA%\ImageCompressor\settings.json`
- installerの前世代backup: `%LOCALAPPDATA%\ImageCompressorInstaller\Backups\`
- installerの展開中データ: Windowsのtemporary folder（処理後に削除）

手動uninstallや設定削除を行う場合は、必要な`settings.json`を先にbackupしてください。第三者へ問題報告を行うときは、画像、file name、full path、設定内容を確認し、個人情報や秘密情報を除いてください。

この説明は現行公開candidateの静的実装に基づきます。将来、外部通信やtelemetryを追加する場合は、実装前にこの文書と利用者同意の要否を更新します。
