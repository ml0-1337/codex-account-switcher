# 手動受け入れ確認

この手順は、ソース検査と合成値テストでは確認できない macOS の実環境だけを対象にする。
実行する人が自分で管理するテスト用アカウント、公式 ChatGPT アプリ、ブラウザー、Keychain
へのアクセスを準備し、各操作を明示的に承認してから実行する。
開発環境の要件は [ビルド手順](installation.md#ソースからビルドする)、
公式アプリの前提は [README](../README.md#使い方) を確認する。

自動確認と実環境の確認には、次の境界がある。

- scripts/check.sh は Swift テスト、Release ビルド、配布スクリプト、公開対象の検査を
  合成値と隔離した一時ディレクトリで実行する。その確認処理は、製品の実アカウント、実 Keychain、
  公式アプリ、ブラウザーを操作しない。Swift やシステムツールが現在の実行環境で動くこと自体は
  隔離対象ではない。この成功は、実ログインやアプリへの反映を証明しない。
- この文書の後半は、人が実アカウントと macOS の確認画面を扱う受け入れ確認である。
  Keychain の許可、ブラウザー認証、公式アプリの再起動、アカウントの表示確認は、自動化
  せず人が判断する。

この手順は現在、実環境では実行していない。別のセッションまたは担当者が、このリポジトリの
文書だけを使って実行するまでは、同じ確認を元の会話なしで再現できるとは判断しない。

## 1. 確認する候補を固定する

作業ディレクトリをリポジトリのルートに固定し、PATH にある既存の codex-switch は使わない。
既存のインストール版が古い場合があるため、後の操作も必ずここで作った絶対パスの候補を使う。
通常の受け入れ確認では候補をインストールせず、dist/codex-switch を直接実行する。
以下は一行ずつ実行し、各行の終了ステータスを確認する。失敗したら次へ進まない。
作業ツリーに変更がある場合は、確認対象のソースを確定してから始める。

~~~sh
# /path/to/codex-account-switcher は、実際のリポジトリのルートへ置き換える
cd /path/to/codex-account-switcher
git rev-parse --verify HEAD
git status --short --branch
./scripts/check.sh
./scripts/build.sh

candidate_path="$PWD/dist/codex-switch"
test -f "$candidate_path" && test -x "$candidate_path" && test ! -L "$candidate_path"
shasum -a 256 "$candidate_path"
codesign --verify --strict --verbose=2 "$candidate_path"
codesign -dvv "$candidate_path" 2>&1 | rg 'Signature=adhoc'
"$candidate_path" help
~~~

合格条件は、対象コミットを記録でき、check.sh と build.sh が終了ステータス 0 を返し、
dist/codex-switch が実行可能な通常ファイルであること、候補の SHA-256 を取得できること、
署名検証が成功し codesign -dvv に Signature=adhoc が表示されること、ヘルプに対応する
コマンドだけが表示されることである。候補バイナリのハッシュは証跡へ記録してよい。

署名・ハッシュ・ヘルプの確認に失敗したら、実アカウントを操作せず停止する。失敗した候補を
インストールしたり、署名検証を省略したりしない。

## 2. 実行前の準備

### アカウントと状態

次を実行者が確認する。

1. すべてのアカウントは実行者本人が正当に管理するテスト用アカウントである。記録上の名前は
   A と B だけを使い、メールアドレスやアカウント ID と A・B の対応表を保存しない。
2. 今回が「初期状態からの setup」か、「既存登録に対する確認」かを先に決める。既存の状態や
   認証情報を削除して初期状態を作らない。登録済みの場合、setup は早期に既存登録を返すため、
   成功しても新規登録や Keychain の許可を証明しない。
3. ~/.codex を通常の共有ホームとして使う。HOME や CODEX_HOME を別の場所へ変更せず、履歴、
   通常の設定、MCP 設定をアカウントごとに複製しない。
4. アカウント A・B のブラウザー認証と 2 段階認証を本人が完了できる状態にする。ログイン用の
   URL とコードは画面上でだけ扱い、証跡へ写さない。

### 競合と権限

- 実行中の Codex タスクがすべて応答を終え、共有の認証ファイルを書き換える操作がないことを
  確認する。作業中のタスクを完了させることは必要だが、killall、pkill、全 PID の終了は
  行わない。
- 旧 GUI 版の Codex Account Switcher と旧 CLI は、確認中に操作しない。公式 ChatGPT アプリは
  公式アプリ自身が管理する app-server 子プロセスだけへ SIGTERM を送り再読み込みを要求する。
  アプリ本体の終了・起動・通知は行わず、再読み込みに失敗した場合だけ人が手動で再起動する。
- macOS の Keychain アクセス制御を弱めない。アクセス許可をリセットするために、ACL の変更、
  Keychain のエクスポート、認証情報の削除・初期化を行わない。
- 実行する端末は標準入力・標準出力とも TTY であることを確認する。変更操作へ tee、script、
  set -x、パイプを付けず、入力と秘密情報をログへ複製しない。list と help の読み取り確認を
  除き、パイプ経由の実行を受け入れ条件にしない。

### 変更前の状態を秘密情報なしで確認する

設定やログインのために必要な本人の準備を先に終え、その直後、各シナリオの開始時に状態を確認
する。準備前の値を基準にしない。auth.json と config.toml は内容を表示せず、比較に必要な値だけを
シェルのメモリへ保持する。

auth.json と config.toml は、操作の前後に同じ方式でハッシュを取得する。取得コマンドの終了
ステータスを直後に保存し、両方の取得が成功した場合だけ比較する。比較結果は unchanged、changed、
unknown のいずれかだけを表示し、ハッシュ値はシェルのメモリから外へ出さない。

~~~sh
# 本人の設定・ログイン準備が終わってから、CLI 操作の前に取得する
auth_before="$(shasum -a 256 "$HOME/.codex/auth.json" 2>/dev/null)"; auth_before_status=$?
config_before="$(shasum -a 256 "$HOME/.codex/config.toml" 2>/dev/null)"; config_before_status=$?
if [[ "$auth_before_status" -ne 0 || "$config_before_status" -ne 0 ]]; then
    printf '%s\n' '比較元を取得できません。unknown と記録し、CLI 操作へ進まないでください。'
fi
~~~

取得できた場合だけ、次節の対象コマンドを一つ実行する。各コマンドの例は、終了ステータスを
直後に command_exit へ保存する。成功・失敗のどちらでも、別の操作へ進む前に次の比較を行う。

~~~sh
auth_after="$(shasum -a 256 "$HOME/.codex/auth.json" 2>/dev/null)"; auth_after_status=$?
config_after="$(shasum -a 256 "$HOME/.codex/config.toml" 2>/dev/null)"; config_after_status=$?
if [[ "$auth_before_status" -ne 0 || "$auth_after_status" -ne 0 ]]; then
    printf '%s\n' 'auth.json: unknown'
elif [[ "$auth_before" == "$auth_after" ]]; then
    printf '%s\n' 'auth.json: unchanged'
else
    printf '%s\n' 'auth.json: changed'
fi
if [[ "$config_before_status" -ne 0 || "$config_after_status" -ne 0 ]]; then
    printf '%s\n' 'config.toml: unknown'
elif [[ "$config_before" == "$config_after" ]]; then
    printf '%s\n' 'config.toml: unchanged'
else
    printf '%s\n' 'config.toml: changed'
fi
~~~

空文字、欠落、失敗したハッシュ同士の一致を「変更なし」として扱わない。比較結果が unknown、
または期待と異なる場合は、別の変更操作へ進まず原因を確認する。外部プロセスによる同時変更と
区別できなければ、CLI に原因があるとは断定しない。

登録情報は、操作前後に list を実行し、登録された A・B と選択マーカーを画面上で比較する。
これは表示の比較であり、state.json 全体や Keychain の不変を証明するものではない。
未設定で list に項目がないことは、初回 setup 前の正常な状態である。

履歴・セッションは、準備後に選んだ既存のローカルタスクを再起動前後に開いて確認する。
その結果は「既存タスクを開けたか」として記録し、ファイル全体のバイト列が不変だったとは記録しない。

履歴・設定・セッションを追加操作で変更しないことの合成値による確認は、
[CoreAcceptanceTests.swift](../Tests/CodexSwitchCoreTests/CoreAcceptanceTests.swift#L219) が担当する。
実環境ではこのテストを再現するためにタスクを新規作成せず、既存タスクを開く確認だけを行う。

## 3. 対応する操作を確認する

すべての変更操作は candidate_path を使って対話的に実行する。表示されたメールアドレスや
ログイン URL・コードを証跡へ残さず、アカウントは A・B として記録する。

### setup

初期状態から確認する場合だけ、共有 ~/.codex/config.toml のトップレベルに、本人が手動で次の
キーを一つだけ設定する。既存のキーを確認してから編集し、MCP などの [table] 内へ追記したり、
同じキーを重複させたりしない。

~~~toml
cli_auth_credentials_store = "file"
~~~

この設定と公式アプリでのログイン準備を完了した後に、前節の auth.json・config.toml の比較元と、
list の表示を確認する。

~~~sh
"$candidate_path" setup
command_exit=$?
printf 'exit_code=%s\n' "$command_exit"
~~~

確認プロンプトへ y を入力する。初期状態で合格とする条件は、終了ステータス 0、アカウント A の
auth.json と config.toml が unchanged、list に A が登録され、選択されていることである。
Keychain への保存・読み戻しは CLI 内の検証に含まれる。macOS の許可画面を確認できたかは別項目として
記録し、秘密値を取り出して照合しない。登録表示に含まれるメールアドレスは画面上だけで確認する。

keyring、auto、またはファイル方式を確認できない設定を拒否する経路は、
[CoreAcceptanceTests.swift](../Tests/CodexSwitchCoreTests/CoreAcceptanceTests.swift#L103) で確認する。
エラーを起こすために普段の設定を変更しない。既存登録に対して終了ステータス 0 になった場合は、
「既存登録を重複させずに返した」ことだけを確認したとし、初期登録・アカウント読み取り・Keychain
許可の証拠にはしない。

### add

setup 済みで、現在の共有認証が A であることを前提にする。add の開始前に、auth.json・config.toml の
比較元と list の表示を確認する。B が既に登録されている場合、同じアカウント ID の追加は拒否される。
登録を削除してやり直さず、追加の成功経路は未確認として扱う。

~~~sh
"$candidate_path" add
command_exit=$?
printf 'exit_code=%s\n' "$command_exit"
~~~

確認プロンプトへ y を入力し、表示された URL とコードをブラウザーで本人が操作する。ログイン完了
後、アカウント B が追加されたことを画面上で確認する。

合格とする条件は、終了ステータス 0、list に B が追加され、選択マーカーが A のままで、
共有 auth.json と config.toml が unchanged であることである。Keychain 保存の読み戻しも完了してから
成功表示が出る。共有の認証ファイルを B へ切り替える操作ではない。

ログインのキャンセル、タイムアウト、ブラウザー認証の失敗は、成功表示がなく、所有する一時
CODEX_HOME だけを後始末することを確認する。CLI が一時領域の削除に失敗した場合は、表示された
正確なローカルパスと理由を証跡へ写さず、実行者だけが保持する。起動したプロセス群が終了したこと
を確認し、対象を絞った後始末を別途判断するまで、そのパスを削除しない。

### list

~~~sh
"$candidate_path" list
command_exit=$?
printf 'exit_code=%s\n' "$command_exit"
~~~

終了ステータス 0 で、登録済みプロファイルと「最後に切替指定したアカウント」の表示だけを確認
する。list が示すのは管理情報であり、起動中の公式 ChatGPT アプリが実際に使っているアカウント
ではない。直前の list と表示が同じで、共有 auth.json と config.toml が unchanged であることを
確認する。表示されたメールアドレスは証跡へ残さない。未完了記録などに触れないことの確認は
[CoreCoordinatorTests.swift](../Tests/CodexSwitchCoreTests/CoreCoordinatorTests.swift#L370) が担当する。

### 引数なしの切り替え

すべてのタスクが応答を終え、切り替えによる共有 auth.json の変更を本人が承認した後、A から B へ
切り替える。開始直前に、auth.json・config.toml の比較元と list の表示を確認する。

~~~sh
"$candidate_path"
command_exit=$?
printf 'exit_code=%s\n' "$command_exit"
~~~

一覧から B の番号を入力し、確認プロンプトへ y を入力する。成功時の末尾は、
[main.swift](../Sources/codex-switch/main.swift#L36) と
[TerminalRunner.swift](../Sources/CodexSwitchCore/Terminal/TerminalRunner.swift#L357) の実装に対応する
次の2行である。

~~~text
認証ファイルを選択したアカウントに切り替えました。
ChatGPTアプリのバックエンドを再起動しました。新しいアカウントで動作します。
~~~

合格とする条件は、終了ステータス 0、共有 auth.json が changed、config.toml が unchanged、
list の選択マーカーが B へ変わり、CLI が公式 ChatGPT アプリ本体を
終了・起動・通知していないことである(app-server 子プロセスへの SIGTERM は許容する)。成功表示は、書き込み完了時点のローカル認証ファイルまで
を示す。サーバー上の認証の有効性や、実行中アプリのアカウントは示さない。

同じプロファイルを選んだ場合は、認証ファイルを変更せず終了ステータス 1 となる。
切り替え成功として記録しない。切り替え開始後に失敗した場合は古い認証を手動で書き戻さず、
残った記録を recover で扱う。

### 手動での公式アプリ確認

切り替え成功後、CLI がアプリの app-server 子プロセスへ SIGTERM を送り、アプリが自動で
バックエンドを再起動する。再読み込みを要求できなかった・再起動を確認できなかった表示の
場合だけ、実行者が公式 ChatGPT アプリを手動で再起動する。CLI やスクリプトからアプリ本体を
終了・起動しない。

アプリ内ターミナルで実行している場合、バックエンドの再起動でそのターミナルのプロセスが
終了することがある。手動での再起動が必要になった場合も同様で、ターミナルとシェル変数が
消えることがある。再起動前に、切り替えの終了ステータス、成功表示、auth.json・config.toml の比較結果、
list の選択マーカー、CLI が報告した保留記録や一時パスの有無を秘密情報なしで匿名化して記録
する。認証ファイルのハッシュを再起動後まで維持するために、永続ファイルへ保存しない。

バックエンド再起動後は、アプリに実際に表示されるアカウント識別情報が B を示すかと、準備時に
選んだ既存のローカルタスクを開けるかを、それぞれ確認する。タスク履歴は共有する設計なので、履歴が見えることを
アカウントの識別には使わない。アカウント表示が曖昧、または確認に必要な画面が表示されない場合は
その項目を unverified と記録する。確認のために新しいモデルタスクを作成しない。

再起動後に CLI の追加操作が必要になった場合は、新しいターミナルでリポジトリへ移動し、candidate_path
を再設定する。候補バイナリを再度ハッシュし、再起動前に記録した候補ハッシュと一致することを確認
してから、明示的な承認を得た操作だけを続ける。アプリや別プロセスによる同時変更が疑われる場合は、
認証ファイルの比較結果を unknown として扱う。

### Keychain の許可・拒否・更新後の再許可

既存の service `app.codex-account-switcher.credentials.v1` と、プロファイル UUID ごとの項目を
引き継ぐ。表示名には `Codex Account Switcher — <アカウントの表示名>` を使う。
アクセス確認がこのツールと意図したアカウントの項目に対応することを、秘密値を表示せず確認する。

setup または切り替えで macOS が既存の Keychain 項目へのアクセスを確認した場合に限り、次を確認
する。確認画面が表示されない場合、この項目は unverified とし、表示を強制するために ACL や
Keychain を変更しない。

1. 許可を選んだとき、承認した操作だけが終了ステータス 0 で完了する。
2. 拒否を選んだとき、終了ステータス 1 で停止し、共有 auth.json は unchanged、成功表示はなく、
   認証情報は削除されない。
3. 未完了記録が残っていない場合、改めて許可して同じ操作を実行し、終了ステータス 0 で完了するかを
   確認する。記録が残った場合は、再実行より先に次の recover の手順で扱う。
4. ad-hoc 署名の候補を更新した後に再許可を求められた場合も、同じ項目だけを対象にする。

許可・拒否・再許可のそれぞれで、Keychain の秘密値や項目全体を表示・エクスポートしない。

### recover

recover は、CLI が実際に未完了記録を残した場合、または管理情報との不整合が実際に発生した場合
だけ確認する。保留記録がない状態で、動作を見るためだけに recover を実行しない。JSON を手動で
作成・編集して保留状態を作らず、壊れた記録や旧形式の記録を実環境へ持ち込まない。

~~~sh
"$candidate_path" recover
command_exit=$?
printf 'exit_code=%s\n' "$command_exit"
~~~

確認プロンプトへ y を入力する。実際の保留記録に対応する共有認証を読み取り、管理情報と Keychain
の必要なレコードを整合させる一方、共有 auth.json を書き換えず、ネットワーク通信や公式アプリ操作
を行わないことを確認する。開始前後の共有 auth.json は unchanged でなければならない。欠落・破損・
対象外の認証や保留記録では終了ステータス 1 で停止し、記録を残す。

登録途中の保留記録は処理の種類で扱いが異なる。setup の未保存記録は、共有認証が記録と一致し、
保存状態が再開可能であれば、その認証を使って登録を再開する。add の認証が未保存の場合は、
追加プロファイルを作らず、回復不能な追加メタデータだけを取り消して add の再実行を案内する。
Keychain に保存済みの認証は削除しない。setup では共有認証と登録対象が一致する必要がある。
add では共有認証は既存の A のままなので、追加対象 B と同じであることを要求しない。

復旧後に元のアカウントへ戻す必要がある場合は、まず recover を完了させる。その後、実行者が明示的
に選んだ場合だけ、通常の切り替えを行い、バックエンドの再読み込み結果を確認する。古い認証のコピーを戻す
操作や、管理 JSON の手動修復は行わない。

## 4. 終了ステータスと失敗の扱い

| 終了ステータス | 意味 | 記録すること |
| ---: | --- | --- |
| 0 | 処理が完了した。help・list も含む | 表示と変更結果を確認する |
| 1 | 認証、ファイル、Keychain、設定、復旧、対話入出力などの処理に失敗した | 成功扱いにせず、変更と保留記録を確認する |
| 2 | コマンドまたは引数が不正 | 対応外の入力として扱う |
| 130 | No、空入力、EOF、q、キャンセル、Ctrl-C（SIGINT） | 成功表示がないことを確認する |
| 143 | SIGTERM による中断 | 成功表示がないことを確認する |

キャンセルや失敗の後に成功表示だけを証跡へ残さない。作業中の保留記録がある場合は、その記録を
削除せず、実際の共有認証と照合できる状態で recover の対象にする。

状態保存、Keychain 保存、共有ファイルの読み書き、競合、破損・旧形式の保留記録、シグナル時の
子・孫プロセス終了範囲を意図的に壊す確認は実環境で行わない。これらは合成テストで確認する。
例えば、切り替えと復旧の失敗・競合は
[CoreCoordinatorTests.swift](../Tests/CodexSwitchCoreTests/CoreCoordinatorTests.swift#L98)、登録途中の
失敗は [RegistrationTests.swift](../Tests/CodexSwitchCoreTests/RegistrationTests.swift#L145)、旧形式と
将来形式の保留記録は [CoreCoordinatorTests.swift](../Tests/CodexSwitchCoreTests/CoreCoordinatorTests.swift#L976)、
一時ホームの削除失敗は [TemporaryCodexHomeTests.swift](../Tests/CodexSwitchCoreTests/TemporaryCodexHomeTests.swift#L6)、
所有したプロセス群だけの終了は [NativeProcessTests.swift](../Tests/CodexSwitchCoreTests/NativeProcessTests.swift#L32)、
確認待ちでのシグナル中断と終了コードは [EntryPointTests.swift](../Tests/CodexSwitchCoreTests/EntryPointTests.swift#L35)
で確認する。

## 5. 後始末

後始末の対象を混同しない。

- add が作った一時 CODEX_HOME は CLI が所有する。通常は自動削除される。削除失敗時は、所有した
  ログインプロセス群の終了を確認するまで、表示されたパスを維持する。/tmp や一時ディレクトリ全体
  をまとめて削除しない。
- 登録済みプロファイル、Keychain レコード、共有の state は意図した管理情報として残る。受け入れ
  確認の後始末として、Keychain のエクスポート・削除・リセットや認証のバックアップ作成を行わない。
- 実際に残った切り替え・登録の保留記録は、recover を完了できるまで残す。JSON を手動で修正したり、
  古い認証をコピーして復元したりしない。
- 受け入れ確認のためだけに作ったアカウントや登録情報を削除する場合は、CLI の通常処理とは別の、
  本人が明示的に選んだ管理作業として扱う。この文書の範囲では削除しない。

比較が終わったシェルでは、認証・設定の比較用変数だけを破棄する。これはファイルを削除しない。

~~~sh
unset auth_before auth_after auth_before_status auth_after_status
unset config_before config_after config_before_status config_after_status
~~~

## 6. 結果の記録テンプレート

下のテンプレートをリポジトリの .verification/ にあるローカル結果ファイルへコピーし、実際のメール
アドレス、アカウント ID、トークン、認証 JSON、Keychain の秘密値、URL、コード、画面キャプチャ、
未加工ログを入れずに記録する。結果ファイルは匿名化したものだけとし、候補バイナリのハッシュだけは
記録してよい。.verification/ は Git 管理外であり、今回は結果ファイルを作成しない。

~~~yaml
source_commit: "<git rev-parse --verify HEAD の値>"
candidate_binary: "dist/codex-switch"
candidate_sha256: "<候補バイナリのハッシュ>"
signature: "ad-hoc / unverified"
environment:
  macos: "<バージョン>"
  swift: "<バージョン>"
  official_chatgpt_app: "<バージョン / build、確認できなければ unverified>"
  bundled_codex: "<バージョン、確認できなければ unverified>"
  terminal: "TTY / unverified"
scenario: "setup | add | list | switch | manual-restart | keychain | recover"
setup_mode: "fresh | existing | not-applicable"
accounts: "A / B only; raw mapping not recorded"
semantic_result: "passed | failed | unverified"
cli_exit_code: "0 | 1 | 2 | 130 | 143 | not-applicable"
selected_profile_before: "A | B | none | unverified"
selected_profile_after: "A | B | none | unverified"
app_account_after_restart: "A | B | ambiguous | not observed"
predicates:
  auth_json: "unchanged | changed | unknown"
  config_toml: "unchanged | changed | unknown"
  existing_local_task: "reopened | missing | unverified"
  keychain_prompt: "allowed | denied | re-permitted | not observed"
residual_data: "<意図して残した登録情報または保留記録。秘密情報は書かない>"
unverified: "<未確認の項目と理由>"
resume_condition: "<再開に必要な準備または承認>"
~~~

この手順の実機実行、実 Keychain の再許可、ブラウザー認証、アプリ再起動後の反映確認は、今回の
ソース実装・自動検証には含まれない。これらを確認するには、別途承認された実行者が、この
リポジトリの文書だけを使って、現在の候補を固定したうえで実行する。

## 7. 配布経路の確認

GitHub Releases と Homebrew の確認は、利用者の CLI を配置・更新する操作を含むため、
対象の Mac と配置先を明示して承認を得てから行う。普段使っている CLI を自動で置き換えない。
この節も未実施であり、CI の成功を受け入れ結果として転記しない。

### ダウンロードした候補

第 1 節のローカルビルドの代わりに、対象のドラフトまたは公開リリースから CPU に合った
アーカイブと `SHA256SUMS` を取得する。アーカイブの SHA-256 を照合して空の作業ディレクトリへ
展開し、その `codex-switch` の絶対パスを `candidate_path` に設定する。
候補の署名検証、バイナリの SHA-256、`help` を確認した後、第 2 節以降を同じ候補で実施する。
記録にはタグ、アーカイブ名と SHA-256、バイナリの SHA-256、macOS、CPU、取得方法を含める。
配布物の確認中にソースからビルドし直したファイルへ差し替えない。

Swift の開発環境がない対応 Mac で `help` と通常操作を確認する。macOS 14 以降を対応範囲として
案内するため、最低対応 OS の確認結果も残す。CPU または OS を確認できなかった場合は未確認と記録する。
ブラウザーからのダウンロード時に macOS が表示した警告・ブロックも記録する。
Gatekeeper の無効化や quarantine 属性の削除を合格条件にしない。

### Homebrew の初回導入

リリースと tap の公開後、対象の Mac で以下を一行ずつ実行する。

~~~sh
brew install ml0-1337/tap/codex-switch
brew test ml0-1337/tap/codex-switch
command -v codex-switch
candidate_path="$(brew --prefix ml0-1337/tap/codex-switch)/bin/codex-switch"
codesign --verify --strict "$candidate_path"
"$candidate_path" help
~~~

PATH 上の実行先が確認した Homebrew 版であることを確かめる。この候補で `setup`、`add`、
切り替え、Keychain の許可を確認する。Homebrew の `test` の成功だけでは認証操作の確認にならない。

### 更新と削除

次のリリースでは、旧バージョンで登録したプロファイルを残した状態で、対象を明示して
`brew upgrade ml0-1337/tap/codex-switch` を実行する。更新したバージョン、署名、実行先を確認し、
新しい候補で `list` と切り替えを行う。Keychain が再許可を求めた場合は本人が判断し、
拒否した場合に成功扱いにならないことを確認する。許可の履歴を消して再現しようとしない。
初回リリースでは、実際の旧版がない更新確認を未確認として残す。

削除を確認する場合は `brew uninstall ml0-1337/tap/codex-switch` を実行する。
Homebrew 管理の CLI が削除され、認証情報・プロファイル・Keychain 項目が残ることを確認する。
この確認のために Keychain の秘密値を表示・エクスポートしたり、登録情報を削除したりしない。
