# 配布スクリプトの仕様

この文書は、`codex-account-switcher` プロジェクトのソースから
`codex-switch` という単一の CLI 実行ファイルを作り、公開対象を検査するための
スクリプト仕様を定める。公式アプリ、公式アプリに
同梱される Codex、GUI、画像、その他のバイナリは配布対象にしない。

## 成果物の境界

`Package.swift` が定める Swift 6・macOS 14 以降の実行ファイル
`codex-switch` だけをビルドする。`scripts/build.sh` は Release 構成で
`swift build --configuration release --product codex-switch` を実行し、既定では
`dist/codex-switch` を作る。開発者は Swift 6、macOS 14 以降、Git、および
`scripts/check-distribution.sh` が要求する PCRE2 対応の `rg` を用意する。

ビルドしたファイルは出力先と同じディレクトリに一時配置し、実行権限を確認してから
`codesign --force --sign -` で ad-hoc 署名する。`codesign --verify --strict` が成功した
後に原子的な `mv` を行うため、検証前のファイルを既存の出力へ置かない。開発者証明書と
notarization はこのローカルビルドに必要ない。`dist` は作業用の生成先であり、Git に
バイナリを追加しない。

## CLI の手動配置と削除

ビルドした `dist/codex-switch` はそのまま実行できる。コマンド名だけで使うための
手動配置と削除の手順は [README](../README.md#手動で配置する場合) にまとめる。

`scripts` はビルドと検査を担当し、利用者の配置先へのインストールや削除は行わない。
手動配置には自動バックアップや失敗時の復元はない。削除の対象は手動配置した CLI
実行ファイルだけであり、認証情報、管理状態、設定、履歴、Keychain 項目は残す。

## 公開前の確認

`scripts/check.sh` が、Swift テスト、Release CLI ビルド、全配布スクリプトの構文確認を
行った後、`scripts/check-distribution.sh` を呼び出す。後者は Swift を起動せず、直接
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
