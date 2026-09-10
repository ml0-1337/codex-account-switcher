# 配布スクリプトの仕様

この文書は、`codex-account-switcher` プロジェクトのソースから
`codex-switch` という単一の CLI 実行ファイルを作り、公開対象を検査するための
スクリプト仕様と GitHub Releases・Homebrew での公開手順を定める。公式アプリ、公式アプリに
同梱される Codex、GUI、画像、その他のバイナリは配布対象にしない。

## 成果物の境界

`Package.swift` が定める Swift 6・macOS 14 以降の実行ファイル
`codex-switch` だけをビルドする。`scripts/build.sh` は Release 構成で
`swift build --configuration release --product codex-switch` を実行し、既定では
`dist/codex-switch` を作る。開発者は Swift 6、macOS 14 以降、Git、および
`scripts/check-distribution.sh` が要求する PCRE2 対応の `rg`、配布定義の検査に使う Ruby を用意する。
プロジェクト名と Swift パッケージ名は `codex-account-switcher`、実行ファイル名は `codex-switch` とする。

ビルドしたファイルは出力先と同じディレクトリに一時配置し、実行権限を確認してから
`codesign --force --sign -` で ad-hoc 署名する。`codesign --verify --strict` が成功した
後に原子的な `mv` を行うため、検証前のファイルを既存の出力へ置かない。開発者証明書と
notarization はこの配布方式に必要ない。配布バイナリも ad-hoc 署名を使う。
`dist` は作業用の生成先であり、Git に
バイナリを追加しない。

## 配布アーカイブと Homebrew 定義

`scripts/release.sh` が配布物を作る。バージョンは `0.1.0` のような
`MAJOR.MINOR.PATCH` とし、タグにだけ `v` を付ける。

```sh
./scripts/build.sh
./scripts/release.sh package 0.1.0 dist/codex-switch dist/archives
```

`package` は入力の CPU を調べ、次のうち対応するファイルを一つ作る。

- `codex-switch-0.1.0-macos-arm64.tar.gz`
- `codex-switch-0.1.0-macos-x86_64.tar.gz`

入力は署名検証できる実行可能な Mach-O ファイルとし、CPU が一つの `arm64` または
`x86_64` であることを確認する。アーカイブには `codex-switch` と `LICENSE` だけを含める。
実行権限と署名を保持し、ファイル所有者のメタデータは固定する。既存の同名アーカイブは
上書きしない。作り直す場合は新しい空の出力先を使う。

両 CPU のアーカイブを同じディレクトリへ集めると、Homebrew の定義を生成できる。
次の処理はネットワークや Homebrew を使わず、アーカイブから SHA-256 を計算する。

```sh
./scripts/release.sh formula 0.1.0 ml0-1337/codex-account-switcher dist/archives > dist/codex-switch.rb
```

定義はバージョン固定の GitHub Releases URL と CPU ごとの SHA-256 を持ち、macOS 14 以降を
要求する。インストール時には `bin.install` で CLI だけを配置する。認証情報の読み取り、
ログイン、Keychain 操作、アプリの起動は行わない。Homebrew の `test` は `help` だけを実行する。
生成された定義を直接修正せず、アーカイブまたは `release.sh` を更新して再生成する。

## CI とドラフトリリース

`.github/workflows/checks.yml` は main への push、Pull Request、手動実行で検査する。
Apple Silicon は `macos-15`、Intel は `macos-15-intel` を使い、Xcode 16.4 を指定する。
両方で `scripts/check.sh`、ad-hoc 署名、アーカイブの展開、バイト比較、CLI の `help` を実行する。
CI 自体は macOS 15 上で動くため、macOS 14 での動作は配布前の別の確認として記録する。

通常の CI では配布物を Actions の artifact に保存し、パッケージのバージョンには検査用の
`0.0.0` を使う。`vMAJOR.MINOR.PATCH` タグへの push の場合は、そのバージョンで両 CPU をビルドし、
両方の検査が成功した後でドラフトリリースを作る。添付するものは次の四つである。

- Apple Silicon 用アーカイブ
- Intel 用アーカイブ
- 両アーカイブの `SHA256SUMS`
- `codex-switch.rb`

GitHub が用意する `GITHUB_TOKEN` だけで動作し、Apple の証明書や追加の公開用トークンは使わない。
リリース作成 job だけに `contents: write` を付与し、checkout は資格情報を保存しない。
すでに同じタグのリリースが存在すると作成に失敗する。途中失敗後の再実行では、既存ドラフトと
添付ファイルを確認してから対応を決め、公開済みのバージョンや配布ファイルを差し替えない。

## 初回公開と更新

本体の公開先は `ml0-1337/codex-account-switcher`、tap は `ml0-1337/homebrew-tap` とする。
ローカルのスクリプト実行は、リポジトリの公開・push・リリース公開の承認を兼ねない。

1. Git 履歴を含めて公開する内容を確認し、GitHub の公開リポジトリへソースを push する。
2. main の CI が成功した候補にバージョンタグを付けて push する。初回の例は `v0.1.0` である。
3. 作られたドラフトから配布物を取得し、SHA-256、署名、対応 OS・CPU、手動受け入れ結果を確認する。
4. リリース本文の未確認事項を実際の結果に更新し、確認した同じアーカイブでリリースを公開する。
5. 添付された `codex-switch.rb` を tap リポジトリの `Formula/codex-switch.rb` に置いて内容を確認する。
   GitHub Releases の URL と SHA-256 が公開したファイルに一致することを確かめ、tap へ commit・push する。
6. 別の確認用 Mac で `brew install ml0-1337/tap/codex-switch` を実行し、`brew test` と手動受け入れを確認する。

以後の更新でも同じ手順を使う。tap の更新後は利用者が
`brew upgrade ml0-1337/tap/codex-switch` で更新できる。tap への自動 push や
利用者の CLI の自動更新は行わない。初回は既存版からの更新を確認できないため、初回導入の
結果と更新の未確認を分けて記録し、次のリリースで確認する。

GitHub Releases からの直接ダウンロードでは、macOS が警告やブロックを出す場合がある。
Homebrew 経由の導入を含め、Gatekeeper や Keychain のアクセス制御を無効にせず確認する。
インストール経路の確認項目は [手動受け入れ確認](manual-acceptance.md#7-配布経路の確認) を参照する。

## CLI の手動配置と削除

ビルドした `dist/codex-switch` はそのまま実行できる。コマンド名だけで使うための
手動配置と削除の手順は [その他の導入方法](installation.md#手動で配置する) にまとめる。

`scripts` はビルドと検査を担当し、利用者の配置先へのインストールや削除は行わない。
手動配置には自動バックアップや失敗時の復元はない。削除の対象は手動配置した CLI
実行ファイルだけであり、認証情報、管理状態、設定、履歴、Keychain 項目は残す。

## 公開前の確認

`scripts/check.sh` が、Swift テスト、Release CLI ビルド、全配布スクリプトの構文確認を
行った後、`scripts/check-distribution.sh` と `scripts/check-release.sh` を呼び出す。
`check-distribution.sh` は Swift を起動せず、直接
実行しても同じ公開スキャンと隔離した一時領域での検出器の合成値テストを行える。
公開対象の一覧は
`git ls-files --cached --others --exclude-standard` で取得し、Git 管理前の新規ファイルも
含める。`.git` と Git 管理下にない `.build`・`dist` の生成物は除外するが、Git 管理下の
同じ場所にあるファイルは除外しない。

内容検査では、秘密鍵、JWT 形式の値、代表的なプロバイダー API トークン、長い秘密値の
代入、個人のメールアドレス、個人の絶対パス、非テキストのバイナリを検出する。公開対象
のファイルに合成値用の例外やマーカーはなく、テスト用の値は実行時に隔離した一時
ディレクトリで検出器ごとに生成する。スキャンは既知の形式を見つけるための補助的な
ヒューリスティックであり、秘密情報がないことを保証しないため、公開前に人が内容を
確認する。

この確認は実アカウント、ネットワーク、実 Keychain、公式アプリ、通常の
`HOME` を使わない。ブラウザー認証、Keychain の再許可、アプリ内ターミナルの操作は
[手動受け入れ確認](manual-acceptance.md) で別に行う。

`check-release.sh` は Apple の C コンパイラーで合成の実行ファイルを作り、両 CPU の
アーカイブ内容、署名と実行権限の保持、上書き拒否、不正入力の拒否、Homebrew 定義の URL・
SHA-256・Ruby 構文を検査する。合成の実行ファイルは起動せず、実際の Homebrew へのインストールも
行わない。配布用 Swift バイナリの動作と Homebrew の導入確認は、これらの合成テストと区別する。
