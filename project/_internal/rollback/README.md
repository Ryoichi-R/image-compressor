# Rollback workspace

このdirectoryは、candidate生成前に現在のinstaller payloadを退避するための空の親directoryです。

過去payload backupは大容量のowner-private運用資産であり、source repositoryへ含めません。fresh checkoutでは、candidate生成前に次のように新しいbackupを作成します。

```powershell
pwsh -NoProfile -File image-compressor/project/scripts/backup-image-compressor-payload.ps1 `
  -DestinationRoot image-compressor/project/_internal/rollback/<timestamp>-payload-v<version>
```

作成された`payload-backup-manifest.json`をcandidate builderへ渡します。backupの削除や上書きは自動では行いません。
