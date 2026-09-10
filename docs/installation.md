# その他の導入方法

通常の導入は [README の Homebrew 手順](../README.md#インストール)を使ってください。
ここでは直接ダウンロード、ソースからのビルド、手動配置を説明します。

## GitHub Releases から取得する

[GitHub Releases](https://github.com/ml0-1337/codex-account-switcher/releases) から、CPU に合う
アーカイブと同じリリースの `SHA256SUMS` を取得します。`uname -m` で CPU を確認できます。

| `uname -m` の結果 | 配布ファイル |
| --- | --- |
| `arm64` | `codex-switch-VERSION-macos-arm64.tar.gz` |
| `x86_64` | `codex-switch-VERSION-macos-x86_64.tar.gz` |

`shasum -a 256` でアーカイブのハッシュを計算し、`SHA256SUMS` の対応する値と照合してください。
一致したファイルを空のディレクトリへ展開し、そのディレクトリで実行します。

```sh
codesign --verify --strict ./codex-switch
./codex-switch help
```

アーカイブの中身は `codex-switch` と `LICENSE` です。
Swift の開発環境は不要です。各コマンドは、[README の使い方](../README.md#使い方)にある
`codex-switch` を `./codex-switch` に読み替えて実行できます。

## 署名について

配布バイナリは ad-hoc 署名を使い、Developer ID 署名・Apple の公証はありません。
この配布方式に Apple Developer Program への加入は不要です。
ダウンロード経路や macOS の設定によって、起動時に警告・ブロックが出る場合があります。
Gatekeeper や Keychain のアクセス制御を無効にする手順は案内していません。

## ソースからビルドする

macOS 14 以降、Swift 6、Git、PCRE2 対応の `rg`、Ruby が必要です。
リポジトリのルートで、次の順に実行してください。

```sh
./scripts/check.sh
./scripts/build.sh
./dist/codex-switch help
```

`build.sh` は Release 構成でビルドし、ad-hoc 署名と署名検証を行ってから `dist/codex-switch` に配置します。
使い方は [README](../README.md#使い方)を参照し、コマンドを `./dist/codex-switch` に読み替えてください。
検査やリリース作成の詳細は、[開発・配布の手順](distribution.md)にまとめています。

## 手動で配置する

既存の CLI がある場合は、先に `command -v codex-switch` で場所を確認してください。
手動配置したファイルと Homebrew 管理のファイルを上書きし合わないようにします。

以下は、ビルドした CLI を `~/.local/bin` に置く例です。既存ファイルは内容を確認し、
必要なら先に退避してください。シンボリックリンクやパッケージマネージャーが管理するファイルには上書きしません。

```sh
mkdir -p "$HOME/.local/bin"
cp -i ./dist/codex-switch "$HOME/.local/bin/codex-switch"
codesign --verify --strict "$HOME/.local/bin/codex-switch"
export PATH="$HOME/.local/bin:$PATH"
codex-switch help
```

手動配置には、自動バックアップや失敗時の復元はありません。
`export` は現在のシェルだけに適用されます。新しいターミナルでも使う場合は、シェルの設定で
`~/.local/bin` を `PATH` に追加してください。

削除するときは、手動配置した CLI であることを確認してから実行します。

```sh
rm -i "$HOME/.local/bin/codex-switch"
```

認証情報、登録情報、設定、履歴、Keychain 項目は残ります。
