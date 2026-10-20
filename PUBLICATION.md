# Publication boundary

Image Compressorは、公開sourceと配布artifactを分離して扱います。この文書は公開対象を説明するものであり、commit、push、repository作成、Release uploadを許可または実行するものではありません。

## 公開sourceに含めるもの

現在はソースのみを公開し、Release assetは公開しません。内部baselineの画像1,000枚と測定結果JSON6件は公開対象から除き、説明READMEとsolutionが参照する計測ツールのソースは保持します。

- Release用の導入・更新BAT template、README、privacy／security文書
- `project/src/`、`project/lib/`、`project/scripts/`、`project/tests/`、設計文書
- SDK、NuGet source、lockfileなどの再現性契約
- `project/installer/`のinstaller実装、文書、設定、legal asset
- `.NET 10.0.10`のライセンス・第三者通知asset
- 性能再測定に必要な`fixture-v2`、正本report、spike harness
- candidate／promotion／rollback用の空ディレクトリ契約README

`project/installer/payload/`の自己完結ZIPと`payload-manifest.json`は公開sourceへ含めません。
source checkoutはbuild可能なsourceとして扱い、一般利用者向けのワンクリック導入は
GitHub Releaseの`image-compressor-installer.zip`で提供します。

## source repositoryから除外するもの

- `project/dist/`: 公開Releaseへ置く生成済み配布artifactの複製
- `project/installer/payload/*.zip`と`payload-manifest.json`: Release assetへ組み込む生成済みbinary
- `project/_internal/build-cache/`: SDK／NuGet／publish cache
- `project/_internal/candidates/`: 過去candidate、作業ディレクトリ、receipt
- `project/_internal/promotions/`: promotion履歴と退避artifact
- `project/_internal/rollback/`: 過去payload backup
- `project/_internal/operations/`とmaster-plan実行記録: owner-private運用記録
- `project/_internal/baselines/runs/`と`fixture-v1/`: 再生成可能またはsupersededな測定資産
- `bin/`、`obj/`、test result、IDE state、log、temporary file

これらを除外してもsource buildとRelease用installer生成には影響しません。一般利用者の導入、更新、自動rollbackは、payloadを同梱したRelease asset内で機能します。clean source checkoutからのcandidate生成には既存payload backupを要求せず、maintainer workspaceに既存payloadがある場合だけ検証済みbackup manifestを必須にします。

## Releaseへ配置するもの

新しいcandidateの正式監査がPASSした場合だけ、candidateの`dist/`から次をRelease asset候補にします。

- `image-compressor-installer.zip`
- `image-compressor-portable-win-x64.zip`
- `image-compressor-installer.manifest.json`

candidate receipt、payload backup、build cacheは公開しません。公開assetとsource repositoryは、同じ`productVersion`、`buildId`、`sourceDigest`へ結び付けます。公開payloadはsymbolなしで生成し、ローカルbuild pathが実行ファイルへ埋め込まれていないことを検証します。

## 公開前確認

Image Compressor本体はルート`LICENSE`のMIT Licenseで提供します。同梱する第三者softwareにはそれぞれのライセンスが適用され、正本と配布境界は`THIRD-PARTY-NOTICES.md`で確認します。

また、初回公開前にGitHubのprivate vulnerability reportingを有効化し、同一candidate snapshotに対する正式な秘密情報・個人情報・履歴・artifact監査を完了させます。
