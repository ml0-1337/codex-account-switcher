# codex-account-switcher

`codex-account-switcher` は、macOS の Keychain に保存した認証情報を使い、
公式の ChatGPT / Codex デスクトップアプリとローカルの Codex CLI が使うアカウントを
切り替えるための非公式 CLI である。
プロジェクト名と Swift パッケージ名は `codex-account-switcher`、
実行ファイルとコマンドの名前は `codex-switch` とする。

`codex-switch` でアカウントを選択し、切り替え後は公式アプリを手動で再起動する。
GUI、公式アプリのコピー、公式アプリに含まれる
Codex、画像などのアセットは配布物に含めない。配布するのは、このプロジェクトから
ビルドした CLI とライセンスだけである。

対象 OS は macOS 14 以降である。Apple Silicon と Intel 用の配布ファイルを提供する。
ビルド済みの CLI の利用に Swift の開発環境は必要ない。ソースからビルドする場合は
Swift 6 と Git、開発時の検査には PCRE2 対応の `rg` と Ruby も必要になる。
通常の切り替えはローカルの共有ファイルと Keychain の既存レコードを
更新して確認するが、Codex の起動、ネットワーク通信、公式アプリの終了・再起動は
行わない。このため、公式アプリがインストールされていない環境でも通常の切り替えは
実行できる。

## リリースと動作確認

[v0.1.0](https://github.com/ml0-1337/codex-account-switcher/releases/tag/v0.1.0) を
試用版（Pre-release）として公開している。

- **実機確認済み**: macOS 26.6.2 / Apple Silicon で、既存アカウント間の切り替え、
  Keychain のアクセス許可、公式アプリを手動で再起動した後のアカウント表示、
  既存のローカルタスクを開けることを確認した。
- **未確認**: 初期状態からの `setup`、ブラウザー認証を伴う `add`、macOS 14 実機での動作、
  Intel 実機でのアカウント切り替え、Homebrew 経由の実際の導入・削除。

自動テストと実機確認の詳しい範囲、更新やダウンロード経路に関する未確認事項は、
上記のリリース説明を参照する。

## 初回の使い方

CLI の[インストール](#インストール)後、通常のターミナルで次の順に操作する。

1. 現在のアカウントで公式アプリにログインし、[`setup` の前提](#setup)に沿って
   `~/.codex/auth.json` とファイル認証の設定を確認する。
2. `codex-switch setup` を実行し、現在のアカウントを最初の切り替え候補として保存する。
3. `codex-switch add` を実行し、表示された URL とコードを使って別のアカウントで
   ブラウザーログインする。追加が完了しても、現在のアカウントは切り替わらない。
4. 実行中のタスクがすべて完了してから `codex-switch` を実行する。切り替え先の番号を選び、
   確認に `y` と答える。成功後は公式アプリを手動で再起動する。

すでにアカウントを登録済みなら、`setup` をやり直す必要はない。`codex-switch list` で
登録を確認し、引数なしの `codex-switch` で切り替える。新しいアカウントが必要な場合に
`add` を使う。

## インストール

### Homebrew

公開済みの [Homebrew tap](https://github.com/ml0-1337/homebrew-tap) からインストールできる。
Homebrew は CPU に合ったビルド済みバイナリを取得する。新しいバージョンが公開された際も、
Homebrew で更新できる。

```sh
brew install ml0-1337/tap/codex-switch
codex-switch help

# 更新
brew upgrade ml0-1337/tap/codex-switch

# CLI の削除
brew uninstall ml0-1337/tap/codex-switch
```

削除後も認証情報、プロファイル、設定、履歴、Keychain 項目は残る。
以前に手動配置した同名の CLI がある場合は `command -v codex-switch` で実行先を確認する。
手動配置したファイルと Homebrew 管理のファイルを上書きし合わないようにする。

### GitHub Releases から取得する場合

Releases から `codex-switch-VERSION-macos-arm64.tar.gz` または
`codex-switch-VERSION-macos-x86_64.tar.gz` と、同じリリースの `SHA256SUMS` を取得する。
`uname -m` が `arm64` なら Apple Silicon、`x86_64` なら Intel 用を選ぶ。
`shasum -a 256` でアーカイブのハッシュを計算し、`SHA256SUMS` の対応する値と照合する。
一致したファイルを空のディレクトリへ展開し、そのディレクトリで次を実行する。

```sh
codesign --verify --strict ./codex-switch
./codex-switch help
```

配布バイナリは ad-hoc 署名済みで、Developer ID 署名・Apple の公証はない。
利用者も公開者も、この方式のために Apple Developer Program へ加入する必要はない。
ダウンロード経路や macOS の設定によって実行時に警告・ブロックが出る場合がある。
Gatekeeper や Keychain のアクセス制御を無効にする手順は使わない。

### ソースからビルドする場合

リポジトリのルートで、次の順に実行する。

```sh
./scripts/check.sh
./scripts/build.sh
./dist/codex-switch help
```

`build.sh` は Release 構成の `codex-switch` をビルドし、`dist/codex-switch` に
置く。出力は同じディレクトリ内で検証してから原子的に置き換え、`codesign --sign -`
による ad-hoc 署名と署名検証を行う。開発者証明書や notarization は必要ない。

以下の CLI 操作例は、コマンド名を `./dist/codex-switch` に読み替えて実行できる。

### 手動で配置する場合

コマンド名だけで実行したい場合は、ビルドした実行ファイルを個人用の配置先へコピーし、
そのディレクトリを `PATH` に追加する。次は `~/.local/bin` を使う例である。
既存の同名ファイルは内容を確認し、必要なら先に退避する。シンボリックリンクや
パッケージマネージャーが管理するファイルは、この手順で上書きしない。

```sh
mkdir -p "$HOME/.local/bin"
cp -i ./dist/codex-switch "$HOME/.local/bin/codex-switch"
codesign --verify --strict "$HOME/.local/bin/codex-switch"
export PATH="$HOME/.local/bin:$PATH"
codex-switch help
```

手動配置には自動バックアップや失敗時の復元はない。削除するときは、手動配置した
この CLI であることを確認してから、実行ファイルだけを削除する。

```sh
rm -i "$HOME/.local/bin/codex-switch"
```

この削除では、認証情報、プロファイル、設定、履歴、Keychain 項目は残る。

## CLI の操作

対話的な変更操作は、引数なしの切り替え、`setup`、`add`、`recover` である。

```text
codex-switch
codex-switch setup
codex-switch add
codex-switch list
codex-switch recover
```

引数なしで実行すると、番号付きのメールアドレスを表示して対象を選び、確認を得て
切り替える。使えるコマンドと引数を確認するときは `codex-switch help`、`-h`、または
`--help` を使う。
未知のコマンドや引数は実行せず、終了ステータス 2 を返す。
`--no-restart`、`switch`、`doctor`、`restart` はコマンドや互換エイリアスとして提供しない。

### `setup`

`setup` は、現在ログインしているアカウントの認証情報を macOS Keychain に保存し、
最初の切り替え候補として登録する。後で別のアカウントに切り替えても、このアカウントへ
戻れるようにするための初回操作である。

通常の登録済み状態で再実行すると、既存の登録を表示して終了する。この場合は新しい登録や
Keychain への保存、公式 Codex の起動を行わない。

初回登録は、現在のアカウントで公式アプリにログインし、`~/.codex/auth.json` が存在する状態で行う。
共有ホームの `~/.codex/config.toml` のトップレベルには、認証のファイル保存を明示する必要がある。
すでに同じキーがある場合は既存の値を確認し、重複させない。`[mcp_servers.…]` などの
テーブル内には追加しない。

```toml
cli_auth_credentials_store = "file"
```

`keyring`、`auto`、またはファイル方式を確認できない構成では、設定の案内を表示して停止する。
`codex-switch` が普段の設定を書き換えることはない。

端末の `セットアップを実行しますか？ [y/N]:` に `y` と答えると処理が始まる。
初回の `setup` は、署名を検証した公式アプリに同梱された Codex を子プロセスとして起動する。
現在の `~/.codex/auth.json` を登録する前に、その app-server の読み取り専用 API で
設定とアカウント情報を確認する。アカウント情報を読む呼び出しでは、
トークン更新を要求しない `refreshToken: false` を使う。ただし、この指定だけで再認証が
絶対に起きないことを保証するものではない。API のエンドポイントと
`account/read` の読み取り条件は App Server の認証仕様に従う。 （[App Server の認証仕様](https://learn.chatgpt.com/docs/app-server)）

確認できた後で、既存の認証ファイルのバイト列をそのまま Keychain に保存し、読み戻して照合する。
表示名、プロファイルの識別子、作成日時などはツールの `state.json` に保存する。
保存時に macOS の Keychain アクセス確認が表示される場合がある。

`setup` 自体は共有の `auth.json` や `config.toml` を書き換えず、公式アプリの GUI を
起動・終了・再起動しない。アカウント情報の確認中に `auth.json` の内容が変わった場合は、
登録を中止する。既存の認証がファイル形式でない場合や、読み取り専用の確認に失敗した場合も、
登録を完了せずにエラーを返す。

### `add`

`add` は、新しいプロファイルの登録を始める。ログインには、署名を検証した公式
アプリに同梱された Codex を使い、デバイスコード用のブラウザー URL とコードを
端末へ表示する。 （[App Server の認証仕様](https://learn.chatgpt.com/docs/app-server)）
公式アプリや同梱バイナリはこのリポジトリにも配布物にも含めない。

新しいログインは専用の一時 `CODEX_HOME` で実行する。
CLI はその一時ホームにだけ、ファイル認証の設定を作成する。
共有ホームの履歴、通常の設定、MCP 構成はコピー・変更しない。
普段の `CODEX_HOME` も変更しない。
新しいログインの完了は、現在選択中のアカウントを変更したり共有認証を切り替えたり
しない。同じメールアドレスの別アカウントは、表示上のメールアドレスの末尾に短い識別子を
付けて区別する。同じ ID を二重登録する要求は拒否する。

公式アプリのインストール確認と署名確認は `setup` と `add` が必要とする場合に限って
行う。通常のファイル切り替えと `recover` は、公式アプリを起動せずに実行する。
署名確認では、公式アプリと同梱 Codex の両方に、Apple 発行の証明書と公式 Team ID を
要求する。これらの確認が成功してから、同梱 Codex を実行する。

### `list`

`list` は登録済みプロファイルの表示名と、最後に選択したプロファイルを示すマーカー
だけを表示する。表示名には必要に応じて、メールアドレス末尾の短い識別子が含まれ、同じ
メールアドレスの別アカウントも区別できる。`list` は状態を変更せず、サーバーの利用状況や
アカウントの有効性を問い合わせる操作でもない。

### `recover`

`recover` は、現在の認証を読み取った結果に合わせて、管理メタデータと Keychain の
レコードを整合させる。認証そのものを修復・書き換えたり、共有認証を作り直したりは
しない。ネットワーク通信をせず、公式アプリを起動・終了・再起動しない。

登録途中で Keychain への保存だけが完了していた場合は、その認証を削除せず登録を完了する。
`setup` の保存前に中断した場合は、共有認証が登録記録と一致することを確認して登録を再開する。
`add` の認証がまだ Keychain に保存されていなかった場合は、現在の共有認証と管理情報を
確認した後に準備記録だけを取り消す。追加するには、改めて `add` を実行する。
保存済みと記録された認証が見つからない場合や、共有認証が欠落・破損・対象不一致の場合は、
記録を残して停止する。

切り替えジャーナルは v3、登録ジャーナルは v2 を使う。古い形式の保留レコードは
新しい形式として解釈せず停止し、表示された手順に従って旧バージョンで操作を完了して
から再実行する。

### 切り替えの完了条件

成功とは、目的の認証ファイルを更新し、ローカルのファイルと Keychain の内容を読み
戻して検証したことを意味する。実行中のアプリがそのアカウントを使っていること、
サーバーがアカウントを有効と判断したこと、次の起動でも同じファイルが残ることまでは
保証しない。アプリや別のプロセスが後から共有ファイルを書き換える場合がある。

作業中のタスクをすべて完了してから切り替えを実行し、切り替えが終わった後に利用者は
公式アプリを手動で再起動する必要がある。`codex-switch` は全体の PID を監視するガード、
GUI、relay、アプリの変更、アプリの再起動、通常操作のネットワーク通信を追加しない。

## 保存先と既存 GUI との関係

共有ホームはこれまでどおり 1 つの `~/.codex` を使う。履歴、設定、MCP 構成を
アカウントごとに複製しない。
ChatGPT Web やクラウドタスクをアカウント間で引き継ぐ機能は含まない。
切り替えツールの状態は次に保存する。

```text
~/Library/Application Support/Codex Account Switcher
```

既存の登録済みプロファイルは state v2、既存の Keychain レコードは vault v1 として
扱う。Keychain サービス名は `app.codex-account-switcher.credentials.v1`、項目キーは
UUID、ラベルは `Codex Account Switcher — email` である。

既存の GUI は CLI と同時に操作しない。GUI はバックアップとして保持し、CLI の通常の
切り替えでは起動しない。既存 Keychain 項目へのアクセスは macOS が確認を求めたり拒否
したりすることがある。アクセス制御を迂回しないため、利用者が許可できない場合は
処理を成功扱いにしない。ad-hoc 署名の更新後は、同じ Keychain 項目でも macOS が再度
許可を求める場合がある。

認証情報の保存方式（file、keyring、auto）の意味は、認証情報の保存仕様を参照する
（2026年9月8日に確認）。 （[認証情報の保存仕様](https://learn.chatgpt.com/docs/auth)）
このプロジェクトはファイル形式を必要とする
操作で設定を自動変更せず、利用者が手動で設定した結果だけを使う。

## 終了ステータス

| ステータス | 意味 |
| ---: | --- |
| `0` | 通常の処理が完了した（`list`、`help` を含む） |
| `1` | 認証、ファイル、Keychain、設定、対話入力、復旧などの処理に失敗した |
| `2` | コマンドまたは引数の構文が不正だった |
| `130` | キャンセル（`No`、空入力、EOF、`q`）または SIGINT（Ctrl-C） |
| `143` | SIGTERM で中断した |

## 開発と公開前の確認

ソースからの再現可能な確認は `scripts/check.sh` に集約する。

```sh
./scripts/check.sh
```

公開スキャンと検出器の合成値テストだけを Swift のビルドなしで確認する場合は、
`./scripts/check-distribution.sh` を直接実行できる。配布アーカイブと Homebrew 定義の
検査だけを行う場合は `./scripts/check-release.sh` を使う。

`check.sh` は Swift のテスト、Release CLI ビルド、すべての配布スクリプトの
`bash -n` の後、`scripts/check-distribution.sh` と `scripts/check-release.sh` を呼び出す。
前者は公開対象の秘密情報・個人パス・非テキストファイルのヒューリスティック検査、
隔離した一時ディレクトリでの検出器ごとの合成値テストを実行する。
`.git` と、Git 管理下にない `.build`・
`dist` の生成物は公開対象から除外するが、Git 管理下の同じ場所にあるバイナリは検査で
拒否する。後者は一時ディレクトリで作った合成の Mach-O 実行ファイルを使い、両 CPU の
アーカイブ内容、署名の保持、既存成果物の保護、Homebrew 定義の URL とハッシュを確認する。
追跡中かどうかにかかわらず、公開予定の新しいファイルは検査する。検査中に
ネットワーク、実アカウント、実 Keychain、公式アプリ、通常の `HOME` は使わない。

スキャンはよくある秘密情報の形を検出するための補助的な検査であり、公開前に人が内容を
確認する必要がある。これだけで秘密情報がないことを保証するものではない。

手動でしか確認できない項目は [手動受け入れ確認](docs/manual-acceptance.md) にまとめる。
ad-hoc 署名後の Keychain 再許可、ブラウザー認証、アプリ内ターミナルでの切り替えと
手動再起動は、ローカルの `check.sh` が成功しても未確認のままである。

GitHub Actions は Apple Silicon と Intel 上で検査し、配布アーカイブから取り出した
CLI の `help` まで確認する。`vMAJOR.MINOR.PATCH` タグを push すると、両 CPU のアーカイブ、
`SHA256SUMS`、Homebrew 定義を添付したドラフトリリースを作る。リリースの公開と tap の
更新は、配布物の確認後に行う。手順は [配布スクリプトの仕様](docs/distribution.md) を参照する。

## ライセンス

Copyright (c) 2026 codex-switch contributors. このソフトウェアは
[MIT License](LICENSE) の条件で利用できる。
