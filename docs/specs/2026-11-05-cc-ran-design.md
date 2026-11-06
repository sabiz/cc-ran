# cc-ran 設計仕様（v1）

- 日付：2026-11-05
- 状態：承認済み（2026-11-06 の修正はレビュー待ち）
- 名称：**cc-ran** = Claude Code - Realtime Activity Notifier

## 0. 目的とスコープ

### 目的

起動中のすべての Claude Code セッションについて、次の状態を一覧で表示します。
- 承認待ち
- 入力待ち
- 作業完了
- エラー
- 作業中
- コンテキスト使用率

**見ればすぐに「どのセッションを確認しに行くべきか」が分かる**ネイティブアプリ（Windows / macOS）を作ります。

### 基本方針

1. **監視（monitor）と表示（UI）を完全に分けます。**
   - 監視側は Claude の状態を集めて SQLite に保存します。
   - UI 側はそれを読んで描画します。
   - 両者は同じモノレポの中にある別々のプロジェクトで、共有するのは `contracts/` だけです。
   - UI の言語やフレームワークは将来入れ替えられるようにします。
2. **Claude Code の設定ファイルは一切書き換えません。** 対象は `settings.json`、`statusLine` などです。Hook はプラグインとして配布し、ユーザー自身が有効にします。
3. **ユーザーが書いた内容や Claude の出力は保存しません。** 保存するのはメタデータ（種別、時刻、ツール名、トークン数など）だけです。
4. **Claude の動作を絶対に邪魔しません。** Hook は常に exit 0 で終わり、stdout には何も出しません。

### v1 の範囲

- ローカルの Claude Code セッションだけを対象にします（`kind` が `interactive` と `bg` のもの）。
- Claude クラウド（claude.ai/code）のセッションは対象外です。一覧を取得する公開 API が存在しないためです。データモデルには `origin`（`local` / `cloud`）を持たせ、将来アダプタを別のサブプロジェクトとして追加できるようにしておきます。

### 開発の分担（TDD）

| 担当 | 内容 |
|---|---|
| Claude | 詳細設計、`contracts/` 一式、テストコード（RED）、コンパイルが通るだけのスケルトン、プロジェクトの初期化、ビルド設定、CI、プラグインのマニフェスト |
| ユーザー | `src/` にあるプロダクトロジックの実装（GREEN）とリファクタリング |

## 1. 全体構成

### 1.1 リポジトリのレイアウト

```
cc-ran/
├─ .claude-plugin/
│  └─ marketplace.json          ローカル marketplace の定義（plugin/ を指す）
├─ plugin/                      Claude Code プラグイン（Hook の配布）
│  ├─ .claude-plugin/plugin.json
│  └─ hooks/hooks.json
├─ contracts/                   言語に依存しない契約。monitor と UI の唯一の接点
│  ├─ schema/
│  │  ├─ 001_init.sql           テーブル、CHECK 制約、公開 VIEW の DDL
│  │  ├─ columns.json           公開 VIEW の列定義（列名、型、NULL 可否）。両側のテストが検証する
│  │  └─ CONTRACT.md            各列の意味、列挙値、バージョン規則
│  ├─ models.json               組み込みのモデル表（コンテキストウィンドウ）
│  ├─ fixtures/
│  │  ├─ hook-inputs/           イベントごとの Hook 入力のサンプル（本文はダミー）
│  │  ├─ session-files/         ~/.claude/sessions/*.json のサンプル
│  │  ├─ transcripts/           usage だけを含む合成の .jsonl
│  │  ├─ scenarios/             入力の並び → 期待する sessions の状態
│  │  └─ db-seeds/              状態ごとの INSERT 文（UI テスト用）
│  └─ README.md
├─ monitor/                     Zig 0.17.1（独立したプロジェクト）
│  ├─ build.zig / build.zig.zon
│  ├─ src/
│  │  ├─ cli/                   サブコマンドの振り分け
│  │  ├─ hook/                  stdin の JSON → events 行
│  │  ├─ daemon/                集約ループ、単一起動、チェックポイント
│  │  ├─ reducer/               状態遷移（純粋関数）
│  │  ├─ context/               コンテキストウィンドウの決定と段階分け
│  │  ├─ store/                 SQLite へのアクセス（extern 宣言）
│  │  ├─ sources/               sessions ファイルと transcript のアダプタ
│  │  └─ platform/              windows/ と macos/（プロセスの生存確認、切り離した起動、パス）
│  ├─ vendor/sqlite/            SQLite の amalgamation
│  └─ tests/
├─ ui/
│  └─ avalonia/                 .NET 10 + Avalonia 12.1.x（独立したプロジェクト）
│     ├─ global.json / Directory.Packages.props
│     ├─ src/CcRan.Ui/          アプリ本体（トレイ、ウィンドウ、View）
│     ├─ src/CcRan.Ui.Core/     ViewModel と DB の読み取り（UI FW に依存しない）
│     └─ tests/                 CcRan.Ui.Core.Tests（xUnit）、CcRan.Ui.Tests（Avalonia.Headless）
├─ docs/specs/
├─ .github/workflows/           monitor.yml / ui.yml / release.yml
└─ .mcp.json
```

- `monitor/` と `ui/avalonia/` は、互いのコードを一切参照しません。
- 将来、別の UI を `ui/<FW名>/` として並べて置けるようにします。

### 1.2 実行時のコンポーネント

| 実体 | 役割 | 寿命 |
|---|---|---|
| `cc-ran hook` | Claude Code の Hook から呼ばれます。stdin の JSON から許可された項目だけを `events` に INSERT し、exit 0 で終わります。 | 一瞬（目標は 50ms 未満） |
| `cc-ran daemon` | `events`、`~/.claude/sessions/*.json`、transcript のメタデータを集約して `sessions` を更新します。生存確認、単一起動の保証、チェックポイント、古いイベントの削除も担当します。 | 常駐 |
| `cc-ran status` | 現在のセッション一覧をテキストで表示します。 | 一瞬 |
| `cc-ran doctor` | PATH、DB への書き込み可否、daemon の生存、Hook の受信実績を確認して表示します。何も修正しません。 | 一瞬 |
| `cc-ran-ui` | トレイアイコンに要対応の件数を出し、一覧ウィンドウで `v_sessions` を表示します。DB は読み取り専用で開きます。 | 常駐 |

- 監視側は 1 つの Zig バイナリ（`cc-ran`）で、サブコマンドで役割を切り替えます。
- **設定ファイルを書き換えるサブコマンド（`install-hooks` など）は作りません。**

### 1.3 daemon の起動

- `cc-ran hook` が `SessionStart` を受け取ったとき、daemon の heartbeat が古ければ、**切り離した独立プロセス**として `cc-ran daemon` を起動します。
  - Windows：`DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW` で、`bInheritHandles = FALSE` にします。`CREATE_BREAKAWAY_FROM_JOB` は付けません（ターミナルから起動した Claude Code では、付けなくても終了後に生き残ることを確認しました）。
  - macOS：`fork` → `setsid` → stdio を `/dev/null` に切り替え → `exec`。
  - どちらも、Hook の stdout のパイプを子プロセスに持たせません。持たせると Claude Code が Hook の終了を待ち続けるおそれがあるためです。
- 起動を二重に試みても安全です。後から起動したほうは、単一起動ロック（§5.3）を取れずにすぐ終了します。
- UI からも「daemon を起動」ボタンで同じ起動を行えます。

## 2. データソース

| ソース | 取れるもの | 位置づけ |
|---|---|---|
| **Hooks**（公式） | 状態の遷移（承認待ち、入力待ち、完了、エラー、作業中）、`session_id`、`cwd`、`transcript_path`、`model`（SessionStart のとき） | 状態判定の主軸 |
| **`~/.claude/sessions/<pid>.json`**（**非公開**の内部ファイル） | セッションの存在、`sessionId`、`name`、`cwd`、`kind`（`interactive` / `bg`）、`status`（`busy` / `idle`）、`pid`、`procStart` | 存在確認、名前、Hook が来ていないときの代替。**形式が変わる前提で adapter に隔離**し、未知のフィールドや欠けたフィールドがあっても動くようにします。 |
| **transcript（`.jsonl`）の末尾** | 最後の assistant メッセージの `message.model` と `message.usage` | コンテキスト使用率 |

- `~/.claude/sessions/*.key` ファイルは**読みません**。
- `procStart` は**プラットフォームごとに形式が違う値**として扱います。
  - Windows：OS のプロセス開始時刻の FILETIME を 10 進の文字列にしたものです（確認済み）。OS から取得した値と比べて、pid の再利用を見分けます。
  - macOS：形式は未確認です（§12）。確認できるまでは、pid の生存だけで判定し、`procStart` は同じ pid の中で値が変わったかどうかの比較だけに使います。
  - `startedAt` は OS のプロセス開始時刻より数秒遅れるので、代わりには使えません。

### 2.1 プライバシー（保存してよい項目の許可リスト）

`events` に保存してよいのは**次の項目だけ**です。

| 項目 | 由来 |
|---|---|
| `hook_event_name` | Hook の入力 |
| `session_id` | Hook の入力 |
| 受信時刻 | hook 側の時計 |
| `cwd` | Hook の入力 |
| `transcript_path` | Hook の入力（使用量を読む場所を知るため） |
| `tool_name` | PreToolUse、PostToolUse、PostToolUseFailure、PermissionRequest |
| `notification_type` | Notification |
| `model` | SessionStart（含まれている場合） |
| `disable_1m` | 環境変数 `CLAUDE_CODE_DISABLE_1M_CONTEXT` が設定されているか（0/1） |
| `session_start_source` | SessionStart の `source`（`startup` / `resume` / `clear` / `compact` / `fork`）。列挙値です |
| `agent_id` | サブエージェントの中で発火した Hook の `agent_id`。不透明な ID です |

**保存しないもの**：`prompt`、`tool_input`、`tool_response`、`message`、`title`、`last_assistant_message`、`error` と `error_details` の本文、`custom_instructions`、`session_title`、transcript の本文。

- transcript から読むのは `type`、`isSidechain`、`message.model`、`message.usage` だけです。
- この方針は RED のテストで保証します（§8.2）。

## 3. 状態判定

### 3.1 Attention state（要対応度の高い順）

| 状態 | 意味 | 移る条件 |
|---|---|---|
| 🔴 `needs_permission` | 承認待ち | `PermissionRequest`、`Notification(permission_prompt)` |
| 🟠 `needs_input` | 質問や入力を待っている | `Notification(elicitation_dialog \| elicitation_url_dialog \| agent_needs_input)` |
| 🟠 `error` | API エラーでターンが止まった | `StopFailure` |
| 🟢 `done` | 作業が完了し、ユーザーの番 | `Stop`、`Notification(agent_completed)` |
| 🔵 `working` | 作業中 | `UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`PostToolUseFailure`、`SubagentStart`、`SubagentStop`、`PreCompact` |
| ⚪ `idle` | 起動直後で、まだ指示を受けていない | `SessionStart`（`source` が `compact` のときを除く） |
| ✖ `ended` | 終了した | `SessionEnd`、またはプロセスの死亡（pid が存在しない、または `procStart` が一致しない） |

### 3.2 遷移のルール（reducer は純粋関数）

- `needs_*` と `error` は、**それを起こしたのと同じエージェントの作業イベントか、メインの `Stop` が来たら解除**します。起こしたエージェントは `sessions.attention_agent_id` に記録します（NULL はメイン）。
  - 許可した場合は `PostToolUse` が来て `working` に戻ります。
  - 拒否した場合は、次の `PreToolUse` か `Stop` が来て解除されます。
  - サブエージェントが起こした場合は、そのサブエージェントの `SubagentStop` でも解除します。
  - **別のエージェントの作業イベントでは解除しません。** 並列のサブエージェントが動き続けていると、承認待ちが数秒で消えてしまうためです。
- `done` は**次の `UserPromptSubmit` が来るまで維持**します。`Notification(idle_prompt)` が来ても、サブエージェントの作業イベントや `SubagentStop` が来ても `done` のままです。Claude Code の内部エージェントの `SubagentStop` は、`SubagentStart` なしで `Stop` の後に届きます（実際に観測しました）。`done` の間に `needs_*` や `error` が起きたら、そちらに移ります。
- `SessionStart` の `source` が `compact` のときは状態を変えません。作業の途中でも発火するためです。それ以外の `source` では、`ended` のセッションも含めて `idle` にします（`--resume` で同じ `session_id` が戻ってきた場合）。
- 知らない `notification_type` と、状態に関係しない `notification_type`（`idle_prompt`、`auth_success` など）では、状態を変えません。
- **Hook のイベントがまだ 1 件もない**セッションは、セッションファイルの値で代用します（`busy` → `working`、`idle` → `idle`）。
- `ended` になったセッションは、猶予時間（§9）を過ぎたら daemon が `sessions` から行を削除します。VIEW に時刻の絞り込みは入れません。
- **イベントの順序**は `events.seq`（AUTOINCREMENT）で決め、`received_at` は補助に使います。Hook は同期で実行します（`async` は使いません）。
- reducer の入出力は「現在の状態とイベント 1 件を受け取り、次の状態を返す」形にし、I/O を持ちません。

### 3.3 並び順（`sort_rank`）

daemon が計算して書き込みます。並べる基準は次の順です。
1. attention の重さ（§3.1 の表の順。`ended` が最後）
2. コンテキストの段階（`critical` → `warn` → `ok` → `unknown`）
3. `last_activity_at` の新しい順

## 4. コンテキスト使用率

### 4.1 使用量

1. transcript を末尾から読み、条件に合う**最後の assistant 行**を探します。対象外にするのは、`isSidechain == true` の行と、`message.model == "<synthetic>"` の行です。
2. その行の `usage` から、使用量 = `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` を計算します。statusline の `used_percentage` と同じ計算式です。
3. 壊れた行は無視します。末尾から一定のサイズ（§9）だけを読みます。

### 4.2 ウィンドウサイズの決定（優先順）

| 優先度 | 決め方 | `window_source` |
|---|---|---|
| 1 | cc-ran の `config.json` の `models` で上書き | `config` |
| 2 | 組み込みのモデル表 `contracts/models.json`。モデル ID は日付の接尾辞（例 `-20251001`）を外して照合します | `builtin` |
| 3 | 使用量が表の値を超えていたら 1M に引き上げ（Opus/Sonnet 4.6 を `[1m]` で使った場合など） | `observed` |
| 4 | 表にないモデルは 200K と仮定します。UI には「推定」と表示します | `fallback` |
| — | モデルも使用量も分からない | `unknown` |

- **`disable_1m = 1`** のセッションは、2〜3 の結果を 200K に置き換えます（1 の config は優先します）。

### 4.3 組み込みのモデル表（初版）

出典：Claude Code ドキュメント「Model configuration」と、Claude API のモデル表（claude-api skill の `shared/models.md`、2026-10-06 時点）。2026-11-05 に確認しました。

| モデル | Claude Code でのウィンドウ |
|---|---|
| Fable 5.1、Fable 5、Mythos 5.1、Mythos 5、Opus 5.5、Opus 5、Opus 4.8、Opus 4.7、Sonnet 5.5、Sonnet 5、Haiku 5.5 | **1,000,000** |
| Opus 4.6、Sonnet 4.6 | **200,000**（`[1m]` を付けて選んだ場合だけ 1M。transcript では区別できないため、§4.2 の 3 で補正） |
| Haiku 4.5 とそれより古いモデル | **200,000** |

- `models.json` には、モデル ID、ウィンドウサイズ、出典、確認日を持たせます。新しいモデルが出たら、このファイルを更新します。
- 照合は、日付の接尾辞を外した ID の**完全一致**です。前方一致にすると、将来の `claude-opus-5-7` が `claude-opus-5` と一致してしまい、`fallback`（「推定」）になりません。
- 古いモデル（Opus 4.5、Sonnet 4.5、Opus 4.1、Sonnet 4、Opus 4）も 200,000 として表に載せ、「推定」と表示されないようにします。

### 4.4 段階分け

| `context_level` | 条件（既定値） |
|---|---|
| `ok` | 70% 未満 |
| `warn` | 70% 以上 |
| `critical` | 90% 以上 |
| `unknown` | 使用量かウィンドウサイズが不明 |

しきい値は `config.json` の `thresholds` で変えられます。

## 5. 永続化と共通契約

### 5.1 保存場所

| OS | ディレクトリ |
|---|---|
| Windows | `%LOCALAPPDATA%\cc-ran\` |
| macOS | `~/Library/Application Support/cc-ran/` |

- 環境変数 `CC_RAN_HOME` で上書きできます（テストや複数環境向け）。
- 置くファイルは `cc-ran.db`（SQLite、WAL モード）と `config.json`（任意）です。
- **`~/.claude` の中には何も書きません。**

`config.json` の形（すべて任意の項目）：

```json
{
  "thresholds": { "warn": 0.70, "critical": 0.90 },
  "models": { "claude-opus-4-6": 1000000 },
  "endedGraceSeconds": 300
}
```

### 5.2 同時アクセスの規則

| 役割 | 実体 | 規則 |
|---|---|---|
| 追記する書き手（複数） | `cc-ran hook`（将来はクラウドのアダプタも） | `events` への INSERT だけを行います。`BEGIN IMMEDIATE` で短いトランザクションにし、`busy_timeout` は約 500ms です。超えたらイベントを捨てて exit 0 で終わります。 |
| 状態を持つ書き手（1 つ） | `cc-ran daemon` | `sessions` と `monitor_state` を書くのは daemon だけです。単一起動ロックで保証します。チェックポイントと古いイベントの削除も daemon が行います。 |
| 読み手（複数） | `cc-ran-ui`、`cc-ran status` | 読み取り専用で開き、**公開 VIEW だけ**を読みます。長いトランザクションは張りません。`PRAGMA data_version` をポーリングして変化を検知します。 |

- 内部スキーマのバージョンは `PRAGMA user_version` で管理し、daemon が起動時にマイグレーションします。

### 5.3 内部テーブル（UI は直接読みません）

- **`events`**（追記専用）
  - `seq` INTEGER PRIMARY KEY AUTOINCREMENT
  - `received_at`
  - `origin`（`local` / `cloud`）
  - `source`（`hook` など）
  - §2.1 の許可リストにある項目
- **`sessions`**（daemon 専用）
  - キーは `session_id`
  - 各ソースから集約した値：`origin`、`pid`、`proc_start`、`name`、`cwd`、`kind`、`transcript_path`、`model`、`disable_1m`
  - 算出した値：`display_name`、`attention`、`attention_since`、`attention_agent_id`、`last_event_seq`、`last_activity_at`、`ended_at`、`context_used_tokens`、`context_window_tokens`、`window_source`、`context_level`、`sort_rank`
- **`monitor_state`**（daemon 専用、**常に 1 行だけ**のテーブル。VIEW を単純にするため、key/value にはしません）
  - `contract_version`
  - 単一起動ロック：`daemon_pid`、`daemon_proc_start`、`daemon_heartbeat_at`、`daemon_stale_ms`
  - `last_processed_seq`
  - `hooks_seen`：一度でも Hook のイベントを受け取ったら 1 にし、以後は戻しません
  - `last_hook_at`：`cc-ran doctor` が表示します
- 正確な定義は `contracts/schema/001_init.sql` にあります。`context_ratio` は `v_sessions` の中で計算します。
- スキーマの適用は、最初に DB に触るもの（`cc-ran hook` か `cc-ran daemon`）が `PRAGMA user_version` を見て行います。
- 列挙値は CHECK 制約で制限します。
- 時刻はすべて UTC の epoch ミリ秒（INTEGER）です。

**単一起動ロック**

daemon は起動時に `BEGIN IMMEDIATE` の中で、ロックを取れるかどうかを次の手順で判定します。
1. heartbeat が古いか、記録されている pid と `procStart` のプロセスが死んでいれば、自分の値で上書きしてロックを取ります。
2. そうでなければ、すぐに終了します。

**イベントの削除**

処理済みで、保持期間（§9）を過ぎた `events` は daemon が削除します。

### 5.4 公開 VIEW（契約）

**`v_sessions`**：1 行 = 1 セッション。猶予時間を過ぎた `ended` は含めません。

| 列 | 型 | NULL | 意味 |
|---|---|---|---|
| `session_id` | TEXT | × | Claude Code の session id |
| `origin` | TEXT | × | `local`（将来 `cloud`） |
| `display_name` | TEXT | × | セッション名。なければ `cwd` の末尾のディレクトリ名 |
| `cwd` | TEXT | ○ | 作業ディレクトリ |
| `kind` | TEXT | × | `interactive` \| `bg` \| `unknown` |
| `attention` | TEXT | × | §3.1 の 7 値 |
| `attention_since` | INTEGER | × | 今の状態になった時刻 |
| `context_used_tokens` | INTEGER | ○ | 使用トークン数 |
| `context_window_tokens` | INTEGER | ○ | ウィンドウサイズ |
| `context_ratio` | REAL | ○ | 使用率。1.0 を超えることもあります |
| `context_level` | TEXT | × | `ok` \| `warn` \| `critical` \| `unknown` |
| `window_source` | TEXT | × | `config` \| `builtin` \| `observed` \| `fallback` \| `unknown` |
| `model` | TEXT | ○ | 最後に観測したモデル ID |
| `last_activity_at` | INTEGER | × | 最後に活動した時刻 |
| `sort_rank` | INTEGER | × | 表示順。UI は `ORDER BY sort_rank` で並べるだけです |

**`v_monitor`**：常に 1 行です。

| 列 | 型 | NULL | 意味 |
|---|---|---|---|
| `contract_version` | TEXT | × | `major.minor`（v1 は `1.0`） |
| `daemon_alive` | INTEGER | × | heartbeat が既定の時間内に更新されていれば 1 |
| `daemon_heartbeat_at` | INTEGER | ○ | 最後の heartbeat |
| `hooks_seen` | INTEGER | × | 0 なら UI は「プラグイン未導入」と案内します |

**規則**

- 並び順と段階分けは daemon が計算します。**UI には判定ロジックを持たせません。**
- 契約のバージョンは `major.minor` です。
  - 列を足すのは minor、列の削除や意味の変更は major です。
  - UI は major が一致するときだけ表示し、一致しなければ「バージョン不一致」と表示します。
- `contracts/schema/columns.json` が VIEW の列定義の正本で、両側のテストがこれを検証します。

### 5.5 fixtures

| ディレクトリ | 内容 | 使う側 |
|---|---|---|
| `hook-inputs/` | 各イベントの Hook 入力。本文の項目には目印になる文字列を入れます | monitor |
| `session-files/` | 実際に観測した形式から作ったサンプル（未知のフィールドや欠けたフィールドを含むもの） | monitor |
| `transcripts/` | usage だけを含む合成の `.jsonl`（sidechain の行、`<synthetic>` の行、壊れた行を含む） | monitor |
| `scenarios/` | 入力の並び → 期待する `sessions` の状態 | monitor（reducer、context） |
| `db-seeds/` | 状態ごとの INSERT 文 | UI |

- fixtures は**Claude が手で書く唯一の正**です。どちらの側も自動生成しません。
- 改行コードは LF に固定します（`.gitattributes`）。

## 6. Hook の導入（Claude Code プラグイン）

### 6.1 導入と解除

1. `cc-ran` を PATH の通った場所に置きます。
   - Windows：`%LOCALAPPDATA%\cc-ran\bin\`
   - macOS：`~/.local/bin/`
2. Claude Code で `/plugin marketplace add <リポジトリのパス か GitHub>` を実行します。
3. 続けて `/plugin install cc-ran@cc-ran` を実行します。
4. 解除するときは `/plugin` から無効化するか、アンインストールします。データを消したい場合は、§5.1 のディレクトリを削除します。

cc-ran は Claude Code の設定ファイルを書き換えません。プラグインの有効化は Claude Code 自身が管理します。

### 6.2 購読するイベント

| 用途 | イベント |
|---|---|
| 存在 | `SessionStart`、`SessionEnd` |
| 作業中 | `UserPromptSubmit`、`PreToolUse`、`PostToolUse`、`PostToolUseFailure`、`SubagentStart`、`SubagentStop`、`PreCompact` |
| 要対応 | `PermissionRequest`、`Notification` |
| 完了／エラー | `Stop`、`StopFailure` |

- matcher は全件にします。
- コマンドは `cc-ran hook` だけで、イベント名は stdin の `hook_event_name` から取ります。
- hooks.json の `timeout` は 5 秒にします。

### 6.3 `cc-ran hook` が必ず守ること

| 項目 | 規則 |
|---|---|
| 終了コード | **常に 0** です。exit 2 は Stop、PreToolUse、PreCompact などをブロックするので使いません。すべてのエラーを捕まえます。 |
| stdout | **何も出力しません**。SessionStart と UserPromptSubmit では、stdout の内容が Claude のコンテキストに入るためです。 |
| stderr | 正常時は何も出力しません。 |
| 実行方式 | 同期で実行します（`async` は使いません）。 |
| 時間 | `busy_timeout` は約 500ms です。超えたらイベントを捨てます。目標は 1 回 50ms 未満です。 |
| 保存する項目 | §2.1 の許可リストだけです。 |
| daemon | SessionStart を受け取ったとき、heartbeat が古ければ起動します（§1.3）。 |
| 最適化レベル | `ReleaseSafe` です。panic したときの終了コードは 2 以外なので、ブロックしません。 |

### 6.4 将来の選択肢

プラグインにバイナリを同梱し、`${CLAUDE_PLUGIN_ROOT}/bin/cc-ran` で呼ぶ方式に切り替える余地を残します（初期化時に検証します）。

## 7. UI（`cc-ran-ui`、Avalonia）

### 7.1 画面

| 部品 | 内容 |
|---|---|
| トレイアイコン | 要対応の件数をバッジで表示します（`needs_permission`、`needs_input`、`error`、`done` の合計）。色は最も重い状態に合わせます。クリックで一覧ウィンドウを開閉します。NativeMenu には「一覧を開く」「daemon を起動」「終了」を置きます。 |
| 一覧ウィンドウ | `v_sessions` を `sort_rank` の順に表示します。各行には次を表示します。<br>・状態のアイコンと色<br>・`display_name`<br>・`cwd`<br>・状態になってからの経過時間<br>・コンテキストのバーと %（`fallback` のときは「推定」バッジ）<br>・`model`<br>・`kind` |
| バナー | 次の 3 種類を出します。<br>・`daemon_alive = 0`：「監視停止中」と「daemon を起動」ボタン<br>・`hooks_seen = 0`：「プラグイン未導入」と、導入手順および `cc-ran doctor` の案内<br>・契約の major が一致しない：「バージョン不一致」 |
| 空の状態 | 「起動中のセッションはありません」と表示します。 |

### 7.2 内部構造

- `CcRan.Ui.Core` は UI FW に依存させません。持たせるのは次の 3 つです。
  - DB の読み取り：Microsoft.Data.Sqlite、`Mode=ReadOnly`
  - `data_version` のポーリング：時計とタイマーは差し替えられる抽象にします
  - ViewModel
- `CcRan.Ui` は View、トレイ、アプリのライフサイクルだけを持ちます。

## 8. テスト戦略と RED/GREEN

### 8.1 進め方

1. Claude がテストとスケルトンを追加し、**失敗することを確認して**コミットします（`test(RED): ...`）。
2. ユーザーが実装して GREEN にし、コミットします。
3. 必要に応じて、Claude がレビューします。

- タスクごとにブランチを切り、GREEN になってから main にマージします。RED のコミットで CI が失敗するのは想定どおりです。
- Zig 0.17 のテストを書くときは、Context7 の `/websites/ziglang`（0.17.0）で API を確認します。

### 8.2 監視側（`zig build test`）

| 層 | 主なテスト |
|---|---|
| `reducer` | `scenarios/` を使って遷移表を網羅します（優先度、`done` の維持、`needs_*` の解除、セッションファイルによる代用、`ended` の猶予期間）。 |
| `context` | ウィンドウの決定順、日付の接尾辞の除去、`disable_1m`、`observed` での引き上げ、しきい値。 |
| `sources` | transcript から usage を取り出す処理（sidechain、`<synthetic>`、壊れた行）、セッションファイルの解析（未知のフィールドや欠けたフィールド）。 |
| `hook`（入力処理） | stdin の JSON から events 行を作る処理（許可リスト以外の項目が捨てられること）。 |
| **プライバシー** | 本文の項目に目印になる文字列を入れた入力を、hook から store まで流します。そのうえで、**DB ファイルと WAL ファイルのバイト列全体**に目印が含まれないことを確かめます。 |
| `store`（結合） | `CC_RAN_HOME` に一時ディレクトリを指定して確かめます。<br>・スキーマの適用と `user_version`<br>・VIEW の列が `columns.json` と一致すること<br>・複数の書き手がいてもイベントが失われないこと<br>・`busy_timeout` を超えたときに捨てる経路<br>・単一起動ロック |
| CLI の契約 | ビルドしたバイナリを実際に実行し、次のどの場合も **exit 0 で stdout が空**になることを確かめます。<br>・正常な入力<br>・壊れた JSON<br>・空の stdin<br>・DB がロックされている<br>・ディレクトリがない |
| `platform` | 自分自身の pid が生存と判定されること、存在しない pid が死亡と判定されること、`procStart` が一致しないこと。切り離した起動のテストには CI 限定のタグを付けます。 |

### 8.3 UI 側（`dotnet test`）

| プロジェクト | 主なテスト |
|---|---|
| `CcRan.Ui.Core.Tests`（xUnit） | `schema/` と `db-seeds/` から一時的な DB を作って確かめます（Zig は使いません）。<br>・`sort_rank` の順に並ぶこと<br>・トレイに出す件数<br>・major が一致しないときの扱い<br>・`daemon_alive = 0` のときのバナー<br>・`hooks_seen = 0` のときの案内<br>・`data_version` が変わったときの再読み込み<br>・読み取り専用で開いていること<br>・VIEW の列が `columns.json` と一致すること |
| `CcRan.Ui.Tests`（Avalonia.Headless、`[AvaloniaFact]`） | 一覧の描画、状態ごとのアイコンと色、「推定」バッジ、コンテキストのバー、バナー、空の状態。 |

### 8.4 手動での E2E 確認

実際に Claude Code を 2〜3 セッション起動し、次の状態が正しく表示されることを目視で確かめます。

| 確かめる状態 | 起こし方 |
|---|---|
| 承認待ち | 許可が必要なツールを実行させる |
| 入力待ち | 質問させる |
| 完了 | — |
| エラー | 可能なら起こす |
| コンテキスト警告 | 長いセッションで起こす |
| 終了 | `/exit` で終了する、またはプロセスを kill する |
| daemon の自動起動と再起動 | — |
| Hook がない状態 | プラグインを入れる前に、セッションファイルによる代用表示と「プラグイン未導入」の案内が出ること |

## 9. 既定値（レビューで確認してください）

本文の中で数値をまだ確定していないものです。**いずれも config で変えられる値か、実装の都合で決める値です。**

| 項目 | 既定値の案 |
|---|---|
| `ended` を一覧から外すまでの猶予時間 | 300 秒 |
| daemon の heartbeat の間隔 | 2 秒 |
| daemon が死んだとみなすまでの時間 | 10 秒 |
| daemon が sessions ファイルと transcript を走査する間隔 | 2 秒 |
| UI が `data_version` をポーリングする間隔 | 1 秒 |
| transcript の末尾から読むサイズ | 256 KiB（見つからなければ倍に広げ、上限は 4 MiB） |
| 処理済みイベントの保持期間 | 24 時間 |
| 警告と危険のしきい値 | 0.70 と 0.90 |
| トレイの件数に含める状態 | `needs_permission`、`needs_input`、`error`、`done` |

## 10. ビルド・CI・配布

### 10.1 バージョンの固定

| 対象 | 固定する方法 |
|---|---|
| Zig 0.17.1 | `build.zig.zon` の `minimum_zig_version` と、CI の setup-zig |
| SQLite | amalgamation を `monitor/vendor/sqlite/` に同梱します。`@cImport` は 0.17 で削除されたので、必要な関数（約 10 個）を `extern` で手書きで宣言します。 |
| .NET 10 SDK | `ui/avalonia/global.json` |
| Avalonia 12.1.x と Microsoft.Data.Sqlite | `Directory.Packages.props` |

### 10.2 成果物

| 成果物 | Windows x64 | macOS arm64 |
|---|---|---|
| `cc-ran`（Zig、`ReleaseSafe`） | ローカルでビルドします | Windows から `-Dtarget=aarch64-macos` でクロスコンパイルします |
| `cc-ran-ui`（Avalonia、Native AOT） | ローカルでビルドします | GitHub Actions の macOS runner で AOT ビルドし、`.app` を作ります |

- mac の `.app` は `LSUIElement=true`（Dock に出さない）にし、署名は ad-hoc（`codesign -s -`）です。quarantine の外し方は README に書きます。
- Windows の AOT ビルドには Visual Studio の C++ ツールが必要です。ILCompiler 10.0.14 は `vswhere.exe` を PATH から探すので、`%ProgramFiles(x86)%\Microsoft Visual Studio\Installer` を PATH に足して発行します。
- AOT の exe は単一ファイルにはなりません。隣に置くネイティブライブラリ（`e_sqlite3`、`libSkiaSharp`、`libHarfBuzzSharp`、`av_libglesv2`）も zip に含めます。

### 10.3 CI

| ワークフロー | 起動する条件 | 内容 |
|---|---|---|
| `monitor.yml` | `monitor/**` か `contracts/**` が変わったとき | `windows-latest` と `macos-latest` で `zig build test` を実行し、クロスコンパイルの成果物を作ります。 |
| `ui.yml` | `ui/**` か `contracts/**` が変わったとき | Windows と macOS で `dotnet test` を実行します。mac では `.app` を作り、ad-hoc 署名します。 |
| `release.yml` | タグ `monitor/v*` か `ui/v*` が付いたとき | zip にまとめて GitHub Release に添付します。 |

- タグは監視側と UI 側で別々に付けます。互換性は `contract_version` で保証します。

### 10.4 インストール（v1 は手動）

1. zip を展開します。
2. `cc-ran` を `bin/` に置いて PATH に追加します。
3. プラグインを導入します。
4. `cc-ran-ui` を起動します。

## 11. v1 の対象外

- Claude クラウド（claude.ai/code）のセッション。`origin` 列で将来に備えます。
- ログイン時の自動起動（v1.1 の候補。Windows は `HKCU\...\Run`、mac は LaunchAgent）。
- OS のトースト通知（v1.1 の候補）。v1 はトレイのバッジだけです。
- 一覧から該当するターミナルやセッションに移動する操作。
- Intel Mac、Windows ARM64、Linux。
- 公証（notarization）と正式な署名。
- プラグインへのバイナリ同梱（§6.4）。

## 12. 初期化時の検証の結果

詳細は `docs/specs/2026-11-05-cc-ran-findings.md` にあります。

| # | 項目 | 結果 |
|---|---|---|
| 1 | ツールチェーン | 完了（Zig 0.17.1、.NET SDK 10.0.403） |
| 2 | Zig 0.17 + SQLite + `aarch64-macos` へのクロスコンパイル | 確認済み（Windows と macOS） |
| 3 | Microsoft.Data.Sqlite と Avalonia のトレイの Native AOT | Windows は確認済み。macOS は発行と SQLite の動作を確認済みで、トレイの目視は**未確認** |
| 4 | 切り離した daemon | 確認済み（Windows のターミナル、macOS runner）。VS Code 拡張やデスクトップアプリから起動した場合は**未確認** |
| 5 | mac の `procStart` の形式 | **未確認**（ユーザーの Mac で後日確認する。plan 01 の macOS の生存確認はこの結果で確定する） |
| 6 | プラグインの hook から PATH 上の `cc-ran` を呼ぶ | Windows は `--plugin-dir` で確認済み。`/plugin install` の経路と macOS は**未確認**（§8.4 で確認） |
| 7 | fixtures の改行コード | 確認済み（`Fixtures_use_lf_only` が Windows と macOS の CI で通る） |

## 13. リスクと前提

| リスク | 内容 | 対策 |
|---|---|---|
| sessions ファイル | `~/.claude/sessions/*.json` は非公開の形式です | adapter に隔離し、壊れても Hook だけで動くようにします。 |
| transcript の形式 | 形式が変わる可能性があります | 必要な項目だけを読み、読めなければ `context_level = unknown` にします。 |
| Opus/Sonnet 4.6 の `[1m]` | 使用量が 200K を超えるまで区別できません | config で上書きできるようにします。 |
| Hook のイベント名や `notification_type` の追加・変更 | 将来変わる可能性があります | 未知の値は無視し、作業系として扱いません。 |
| プラグインを後から無効にした場合 | `hooks_seen` は 1 のまま戻らないため、「プラグイン未導入」の案内は出ません | v1 では許容します。`cc-ran doctor` で最後に Hook を受け取った時刻を表示します。 |
| 複数のエージェントが同時に承認待ちになった場合 | `attention_agent_id` は 1 つだけなので、片方の解決で解除されます | v1 では許容します。もう片方は、次の `PermissionRequest` か `Notification(permission_prompt)`（約 6 秒後）で戻ります。 |
| `Stop` の後のバックグラウンド作業 | `Stop` の `background_tasks` が空でなくても `done` と表示します | v1 では許容します（将来の候補）。 |
