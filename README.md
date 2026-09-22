# OwnTone Runtime for macOS

[OwnTone](https://github.com/owntone/owntone-server) を Apple Silicon 向けにビルドし、AirPlay / Chromecast 配信に使う再配置可能なランタイムを生成します。汎用の OwnTone ディストリビューションではありません。

## 必要環境

- Apple Silicon Mac
- macOS 14 以降
- Xcode Command Line Tools
- `autoconf`、`automake`、`libtool`、`pkg-config`、`cmake`、`gperf`

Homebrew を使う場合:

```zsh
brew install autoconf automake libtool pkg-config cmake gperf
```

## ビルド

```zsh
./Scripts/build-owntone-runtime.sh
```

成果物は `dist/owntone-runtime/` に生成されます。ソースのバージョンと SHA-256 は [`Scripts/owntone-sources.lock`](Scripts/owntone-sources.lock) で固定され、OwnTone への変更内容は [`patches/OwnTone-29.3/README.md`](patches/OwnTone-29.3/README.md) に記載されています。

利用できるオプションは次のコマンドで確認できます。

```zsh
./Scripts/build-owntone-runtime.sh --help
```

## リリース

配布用の対応ソースアーカイブも生成します。

```zsh
./Scripts/build-owntone-runtime.sh --emit-source-archive
```

`dist/owntone-runtime/` を圧縮したバイナリと、生成された `dist/owntone-corresponding-source-<version>.tar.gz` を同じ GitHub Release に添付してください。

## ライセンス

このリポジトリと `patches/` の変更は GPL-2.0-or-later です。詳細は [`COPYING`](COPYING) を参照してください。各コンポーネントのバージョンと取得元は、ビルド後の `dist/owntone-runtime/SOURCES.txt` に記録されます。
