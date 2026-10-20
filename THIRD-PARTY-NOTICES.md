# Third-party notices

Image Compressorの自己完結binaryには、Microsoftおよび.NET Foundationが提供する.NET 10.0.10 Runtime／Windows Desktop Runtimeが含まれます。

配布payloadには次の原文通知を同梱し、`payload-manifest.json`のmanaged fileとしてSHA-256検証します。

- `DOTNET-LICENSE.txt`
- `DOTNET-THIRD-PARTY-NOTICES.txt`
- `WINDOWSDESKTOP-LICENSE.txt`

source上の正本は[`project/installer/assets/legal/`](project/installer/assets/legal/)にあります。各runtime ZIPにも同じfileを含めます。

これらは第三者softwareの通知であり、Image Compressor本体のライセンスを定めるものではありません。本体のライセンスはルート`LICENSE`で別途定めます。
