# Third-party notices

Image Compressorの自己完結binaryには、Microsoftおよび.NET Foundationが提供する.NET 10.0.13 Runtime／Windows Desktop Runtimeが含まれます。

配布payloadには次の原文通知を同梱し、`payload-manifest.json`のmanaged fileとしてSHA-256検証します。

- `DOTNET-LIBRARY-LICENSE.html`
- `DOTNET-LICENSE.txt`
- `DOTNET-THIRD-PARTY-NOTICES.txt`
- `WINDOWSDESKTOP-LICENSE.txt`

source上の正本は[`project/installer/assets/legal/`](project/installer/assets/legal/)にあります。各runtime ZIPにも同じfileを含めます。

これらは第三者softwareの通知であり、Image Compressor本体のライセンスを定めるものではありません。本体のライセンスはルート`LICENSE`で別途定めます。

採用Runtime pack 10.0.13のLICENSE／第三者通知はx64とARM64の同梱原文を照合して使用します。ファイル末尾の改行がない場合だけ、既存の改行形式で1つ追加します。本文、著作権表示、第三者連絡先は変更しません。NuGet生成lockfileもJSONの内容を変えず末尾改行だけを正規化します。依存更新で再生成した場合も、locked restoreで内容・hashの不変を確認します。

Windowsの自己完結配布に含まれる.NET Runtimeには、source repositoryのMIT表記だけでなく、Microsoftの[Windows license information](https://github.com/dotnet/core/blob/main/license-information-windows.md)が案内する[.NET Library License](https://dotnet.microsoft.com/en-us/dotnet_library_license.htm)も確認してください。公式のライセンス文書を`DOTNET-LIBRARY-LICENSE.html`として同梱します。本体のMIT LICENSEが同梱Runtimeの条件を置き換えるものではありません。
