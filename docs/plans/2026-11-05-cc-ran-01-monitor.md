# cc-ran 01 — 監視側（monitor）実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans。各ステップに担当（**[Claude]** / **[User]**）を付けてある。**[User]** のステップでは必ず止まり、完了の連絡を受けてから再開する。**[Claude] は `monitor/src/` のロジックを書かない**（スケルトンまで）。ユーザーが GREEN を頼んだ場合だけ例外。

**Goal:** `cc-ran hook` / `daemon` / `status` / `doctor` を実装し、Claude Code のセッションの状態を `v_sessions` と `v_monitor` に出せるようにする。

**Architecture:**
- Zig の 1 バイナリで、サブコマンドで役割を切り替える。
- 純粋なロジック（reducer、context、rank、入力の解析）と I/O（store、platform、daemon のループ）を分ける。純粋な部分は allocator とスライスだけで動かす。
- `contracts/` だけに依存し、UI のコードは参照しない。

**Tech Stack:** Zig 0.17.1、SQLite 3.54.1（`monitor/vendor/sqlite/`、`src/store/sqlite_c.zig` の `extern` 宣言）

**Spec:** `docs/specs/2026-11-05-cc-ran-design.md`（検証結果：`docs/specs/2026-11-05-cc-ran-findings.md`）

## Global Constraints

### Claude の動作を邪魔しない
- `cc-ran hook` は**常に exit 0** で終わり、**stdout に何も出さない**。正常時は stderr にも出さない。exit 2 は使わない。
- `busy_timeout` は 500ms。超えたらイベントを捨てて exit 0。目標は 1 回 50ms 未満。
- 最適化レベルは `ReleaseSafe`。

### プライバシー
- `events` に保存してよいのは spec §2.1 の許可リストだけ：`hook_event_name`（列名 `event`）、`session_id`、受信時刻、`cwd`、`transcript_path`、`tool_name`、`notification_type`、`model`、`disable_1m`、`session_start_source`、`agent_id`。
- `prompt`、`tool_input`、`tool_response`、`message`、`title`、`last_assistant_message`、`error`、`error_details`、`custom_instructions`、`session_title`、transcript の本文は保存しない。
- transcript から読むのは `type`、`isSidechain`、`message.model`、`message.usage` だけ。
- **Claude Code の設定ファイルを書き換えない。`~/.claude` の中に書き込まない。`~/.claude/sessions/*.key` を開かない。**

### 同時アクセス
- `events` は複数の hook が追記する。`sessions` と `monitor_state` を書くのは daemon だけ（単一起動ロックで保証）。
- 書き込みは `BEGIN IMMEDIATE` の短いトランザクションで行う。
- スキーマの適用：WAL への切り替えはトランザクションの外で行う。その後 `BEGIN IMMEDIATE` → `user_version` を読み直す → 0 なら `001_init.sql` を流す → COMMIT。
- 時刻はすべて UTC の epoch ミリ秒。

### Zig の規約
- テストは `monitor/tests/` に別ファイルで置き、`build.zig` の `test_files` に登録する。`src/` に `test` ブロックを書かない。
- テストは `@import("cc_ran")`（`src/root.zig`）から公開 API を使う。
- **スケルトンはエラー共用体を返す**（`!T`、本体は `_ = param; return error.NotImplemented;`）。pure な関数も同じ。`@panic` や `unreachable` は使わない（テストのバイナリごと落ちて、他の RED の結果が見えなくなるため）。
- 各テストファイルで `std.testing.refAllDecls` を呼ぶ。
- I/O を行う関数は `io: std.Io` を受け取る。テストでは `std.testing.io`、`std.testing.allocator`、`std.testing.tmpDir(.{})` を使う。
- std の API はインストール先の `lib/std` で確かめる（`zig env` の `lib_dir`）。

### 既定値（spec §9）
| 名前 | 値 |
|---|---|
| `ended` の猶予 | 300,000 ms（config の `endedGraceSeconds` で変更可） |
| heartbeat の間隔 / 死亡とみなす時間 | 2,000 ms / 10,000 ms |
| 走査の間隔 | 2,000 ms |
| transcript の末尾 | 256 KiB から倍々に広げ、上限 4 MiB |
| 処理済みイベントの保持 | 24 時間 |
| Hook だけのセッション（pid 不明）の失効 | 最後の活動から 24 時間 |
| Esc の補正 | `status=idle` が 3,000 ms 続いたら |
| しきい値 | warn 0.70、critical 0.90 |

## 進め方（すべてのタスクで共通）

1. **[Claude]** ブランチを切り、fixtures、テスト、スケルトンを書く。
2. **[Claude]** `cd monitor; zig build test` を実行し、**コンパイルが通り、新しいテストが `error.NotImplemented` か期待値の不一致で失敗する**ことを確かめて、`test(RED): ...` でコミットする。テストが最初から通る場合は、理由を報告する（ガードのテストだけは通ってよい。タスクの中で明記してある）。
3. **[User]** スケルトンの中身を実装する。
4. **[Claude]** `zig build test` と `zig build -Dtarget=aarch64-macos` を実行し、結果を確かめて、ユーザーの了解を得て main にマージする。レビューを頼まれたら行う。

## Review Focus

spec が前提にしているのに、見落としやすい条件。それぞれのテストは担当のタスクに入れてある。

1. **並列のサブエージェント**：あるエージェントの承認待ちが、別のエージェントの作業イベントで消えないこと。（Task 2）
2. **`/clear` と `--resume`**：同じ pid で新しい `session_id` になる、同じ `session_id` が新しい pid で戻る。重複した行を作らず、誤って `ended` にしないこと。（Task 7）
3. **最初の接触の競合**：複数のセッションが同時に起動して、複数の hook が同時に空の DB に触っても、スキーマの適用とイベントが失われないこと。（Task 6）
4. **daemon の作業ディレクトリ**：daemon が動いている間も、セッションのプロジェクトフォルダを削除できること。（Task 8）
5. **ASCII 以外のパス**：日本語の `CC_RAN_HOME`、`cwd`、transcript のパスを正しく扱えること。（Task 4、6、7、8）

---

### Task 1: モジュール構成とスケルトンの土台（検証のみ、GREEN なし）

**Files:**
- 作成：`monitor/src/root.zig`、`monitor/src/model.zig`、`monitor/tests/support.zig`、`monitor/tests/model_test.zig`
- 変更：`monitor/build.zig`

**Interfaces:**
- Produces（`build.zig`）
  - `src/root.zig` を名前付きモジュール `cc_ran` にし、すべてのテストと `main.zig` から import する。`sqlite_c` と `init_sql` は `cc_ran` モジュールに与える。
  - テスト用のビルドオプション `test_options` を与える：`contracts_dir`（絶対パス）、`cc_ran_exe`（`addOptionPath` で実行ファイルのパス。CLI のテストが使う）。
  - `init_sql` に加えて、`models_json`（`../contracts/models.json`）も埋め込む。
- Produces（`src/model.zig`）

  ```zig
  pub const Attention = enum { needs_permission, needs_input, @"error", done, working, idle, ended };
  pub const ContextLevel = enum { ok, warn, critical, unknown };
  pub const WindowSource = enum { config, builtin, observed, fallback, unknown };
  pub const Kind = enum { interactive, bg, unknown };
  pub const FileStatus = enum { busy, idle, unknown };

  /// events の 1 行。許可リストの項目だけを持つ。
  pub const EventRow = struct {
      received_at: i64, session_id: []const u8, event: []const u8,
      cwd: ?[]const u8 = null, transcript_path: ?[]const u8 = null,
      tool_name: ?[]const u8 = null, notification_type: ?[]const u8 = null,
      model: ?[]const u8 = null, disable_1m: ?bool = null,
      session_start_source: ?[]const u8 = null, agent_id: ?[]const u8 = null,
  };
  pub const StoredEvent = struct { seq: i64, row: EventRow };
  pub const AttentionState = struct { attention: Attention, since: i64, agent_id: ?[]const u8 = null };
  ```

- Produces（`tests/support.zig`）：`readContract(gpa, sub_path) ![]u8`（`contracts/` の下のファイルを読む）

- [ ] **Step 1 [Claude]:** ブランチ `chore/monitor-modules` を切り、上のファイルを書く。
- [ ] **Step 2 [Claude]:** `tests/model_test.zig` を書く。`Attention` の名前の集合が `contracts/schema/001_init.sql` の CHECK 制約の 7 値と一致し、`ContextLevel`、`WindowSource`、`Kind` も同様に一致する（`support.readContract` で読んだ SQL に `'<値>'` が含まれる）。
- [ ] **Step 3 [Claude]:** 確かめる。
  - 実行：`cd monitor; zig build test; zig build -Dtarget=aarch64-macos`
  - 期待：すべて成功する。
- [ ] **Step 4 [Claude]:** コミットする（`chore(monitor): module graph and model types`）。

---

### Task 2: reducer（状態遷移）

**Files:**
- 作成：`monitor/src/reducer.zig`（スケルトン）、`monitor/tests/reducer_test.zig`、`contracts/fixtures/scenarios/*.json`、`contracts/fixtures/scenarios/README.md`

**Interfaces:**
- Consumes：`model.AttentionState`、`model.EventRow`
- Produces：

  ```zig
  pub fn initial(at: i64) !AttentionState;                 // idle
  pub fn apply(state: AttentionState, event: EventRow) !AttentionState;
  pub fn reconcile(state: AttentionState, status: FileStatus, status_updated_at: ?i64, now: i64) !AttentionState;
  ```

- シナリオの形式：`{"name": "...", "start": {"attention": "idle", "since": 0}, "steps": [{"at": 10, "input": "PreToolUse", "expect": {"attention": "working", "since": 10, "agent_id": null}}]}`。`input` は `hook-inputs/` の fixture 名で、`at` が `received_at`。
- `apply` の規則（spec §3）：**状態が変わらないときは `since` も `agent_id` も変えない。**

| イベント | 動作 |
|---|---|
| `SessionStart`（`source != compact`） | `idle`（`ended` からも戻る） |
| `SessionStart`（`source == compact`） | 変えない |
| `SessionEnd` | `ended` |
| `UserPromptSubmit` | `working`（`done` と `needs_*` と `error` をすべて解除。`ended` は除く） |
| `PermissionRequest`、`Notification(permission_prompt)` | `needs_permission`、`agent_id` を記録（`ended` は除く） |
| `Notification(elicitation_dialog / elicitation_url_dialog / agent_needs_input)` | `needs_input`、`agent_id` を記録（`ended` は除く） |
| `StopFailure` | `error`（`ended` は除く） |
| `Stop`、`Notification(agent_completed)` | `done`（`ended` は除く） |
| `PreToolUse`、`PostToolUse`、`PostToolUseFailure`、`SubagentStart`、`PreCompact` | `idle` と `working` なら `working`。`needs_*` と `error` は **`agent_id` が一致するときだけ** `working`。`done` と `ended` は変えない |
| `SubagentStop` | `needs_*` と `error` で `agent_id` が一致するときだけ `working`。それ以外は変えない（`idle` も `working` に**しない**） |
| その他のイベント、その他の `notification_type` | 変えない |

- `reconcile`：`working` かつ `status == .idle` かつ `status_updated_at > since` かつ `now - status_updated_at >= 3000` のとき、`idle`（`since = status_updated_at`）。それ以外は変えない。

- [ ] **Step 1 [Claude]:** シナリオとテストを書く。各シナリオの `steps` を順に `apply` し、毎回 `expect` と比べる。必須のシナリオ：
  - `basic-turn`：`SessionStart.startup` → `UserPromptSubmit` → `PreToolUse` → `PostToolUse` → `Stop` で `idle → working → done`。`working` の `since` は `UserPromptSubmit` の時刻のまま。
  - `permission-approved`：`PreToolUse` → `PermissionRequest` → `PostToolUse` で `working → needs_permission → working`。
  - `permission-denied-then-stop`：`PermissionRequest` → `Stop` で `done`。
  - `permission-notification-after-request`：`PermissionRequest` → `Notification.permission_prompt` で `since` が変わらない。
  - `parallel-subagent-keeps-permission`：`PermissionRequest.subagent` → `PostToolUse`（メイン）→ `PreToolUse`（メイン）で `needs_permission` のまま。その後 `PostToolUse.subagent` で `working`。
  - `main-permission-ignores-subagent`：`PermissionRequest` → `PostToolUse.subagent` で `needs_permission` のまま。
  - `subagent-stop-clears-own-permission`：`PermissionRequest.subagent` → `SubagentStop` で `working`。
  - `done-survives-internal-agent`：`Stop` → `SubagentStop.internal` で `done` のまま（観測済みの順序）。
  - `done-survives-background-work`：`Stop` → `PreToolUse.subagent` → `Notification.idle_prompt` で `done` のまま。
  - `done-interrupted-by-permission`：`Stop` → `PermissionRequest.subagent` で `needs_permission`。
  - `done-cleared-by-prompt`：`Stop` → `UserPromptSubmit` で `working`。
  - `idle-not-woken-by-subagent-stop`：`SessionStart.startup` → `SubagentStop.internal` で `idle` のまま。
  - `compact-keeps-working`：`UserPromptSubmit` → `SessionStart.compact` で `working` のまま、`since` も変わらない。
  - `error-then-prompt`：`StopFailure` → `UserPromptSubmit` で `error → working`。
  - `input-then-stop`：`Notification.elicitation_dialog` → `Stop` で `needs_input → done`。
  - `ended-is-final-until-restart`：`SessionEnd` → `PreToolUse` → `Stop` で `ended` のまま。その後 `SessionStart.resume` で `idle`。
  - `unknown-ignored`：`auth_success` の通知と、`event = "FutureEvent"` で変わらない。
  - `reconcile` の単体テスト：`Esc で working が idle になる`、`status_updated_at <= since なら変えない`、`3 秒未満なら変えない`、`done と needs_permission は変えない`、`status_updated_at が null なら変えない`。
- [ ] **Step 2 [Claude]:** RED を確かめてコミットする（`test(RED): reducer scenarios`）。
- [ ] **Step 3 [User]:** `src/reducer.zig` を実装する。
- [ ] **Step 4 [Claude]:** GREEN を確かめる。

---

### Task 3: コンテキストとモデル表、設定、並び順

**Files:**
- 作成：`monitor/src/context.zig`、`monitor/src/config.zig`、`monitor/src/rank.zig`（スケルトン）、`monitor/tests/context_test.zig`、`monitor/tests/config_test.zig`、`monitor/tests/rank_test.zig`

**Interfaces:**

```zig
// context.zig
pub const ModelTable = struct {
    default_window: u64, one_million: u64, // 中身はユーザーが決める
    pub fn parse(arena: Allocator, json: []const u8) !ModelTable;
    pub fn lookup(self: ModelTable, id: []const u8) !?u64;
};
pub const Window = struct { tokens: ?u64, source: WindowSource };
pub fn stripDateSuffix(model: []const u8) ![]const u8;  // 末尾の -YYYYMMDD だけを外す
pub fn resolveWindow(table: ModelTable, overrides: *const Config, model: ?[]const u8, used: ?u64, disable_1m: bool) !Window;
pub fn level(used: ?u64, window: ?u64, config: *const Config) !ContextLevel;

// config.zig
pub const Config = struct { warn: f64 = 0.70, critical: f64 = 0.90, ended_grace_ms: i64 = 300_000 /* models は実装者が持つ */ };
pub fn parse(arena: Allocator, json: []const u8) !Config;  // 壊れた JSON は既定値にする
pub fn modelOverride(self: *const Config, id: []const u8) !?u64;

// rank.zig
pub const RankInput = struct { session_id: []const u8, attention: Attention, level: ContextLevel, last_activity_at: i64 };
/// out[i] に inputs[i] の表示順（0 始まり）を入れる
pub fn assign(gpa: Allocator, inputs: []const RankInput, out: []i64) !void;
```

- [ ] **Step 1 [Claude]:** テストを書く。
  - `stripDateSuffix`：`claude-haiku-4-5-20251001` → `claude-haiku-4-5`、`claude-opus-5-5` → そのまま、`claude-opus-4-20250514` → `claude-opus-4`、`claude-foo-123` → そのまま。
  - `resolveWindow`（`contracts/models.json` を使う）：
    - `claude-opus-5-5`、used 717,000 → 1,000,000、`builtin`。
    - `claude-haiku-4-5-20251001` → 200,000、`builtin`。
    - `claude-opus-4-6`、used 500,000 → 1,000,000、`observed`。
    - `claude-opus-4-6`、used 150,000 → 200,000、`builtin`。
    - `claude-future-9`、used 40,000 → 200,000、`fallback`。
    - `claude-future-9`、used 500,000 → 1,000,000、`observed`。
    - `claude-opus-5-7`（前方一致してはいけない）→ `fallback`。
    - config の `claude-opus-4-6: 1000000`、used 10 → 1,000,000、`config`。
    - `disable_1m` で `claude-opus-5-5` → 200,000、`builtin`。used 500,000 でも 200,000（`observed` にしない）。
    - `disable_1m` と config の上書き → config が優先。
    - model が null で used も null → `tokens = null`、`unknown`。
    - model が null で used あり → 200,000、`fallback`。
  - `level`：used 139,999 / 200,000 → `ok`、140,000 → `warn`、180,000 → `critical`、300,000 → `critical`、null や window 0 → `unknown`。config で warn を 0.5 にすると 100,000 → `warn`。
  - `config.parse`：spec §5.1 の例、空の `{}`、壊れた JSON、未知のキーのどれでも成功する。
  - `rank.assign`：`needs_permission < needs_input < error < done < working < idle < ended`。同じ attention なら `critical < warn < ok < unknown`。それも同じなら `last_activity_at` の新しい順。それも同じなら `session_id` の昇順。空の入力でも成功する。
- [ ] **Step 2 [Claude]:** RED を確かめてコミットする（`test(RED): context, config, rank`）。
- [ ] **Step 3 [User]:** 3 つのファイルを実装する。
- [ ] **Step 4 [Claude]:** GREEN を確かめる。

---

### Task 4: 入力の解析（Hook、セッションファイル、transcript）

**Files:**
- 作成：`monitor/src/hook_input.zig`、`monitor/src/sources/session_file.zig`、`monitor/src/sources/transcript.zig`（スケルトン）、`monitor/tests/hook_input_test.zig`、`monitor/tests/session_file_test.zig`、`monitor/tests/transcript_test.zig`

**Interfaces:**

```zig
// hook_input.zig
pub fn parse(arena: Allocator, json: []const u8, received_at: i64, disable_1m: bool) !EventRow;
// session_id か hook_event_name がなければ error.MissingField、壊れた JSON は error.InvalidJson

// sources/session_file.zig
pub const SessionFile = struct {
    session_id: []const u8, pid: i64, proc_start: ?[]const u8, cwd: ?[]const u8,
    name: ?[]const u8, kind: Kind, status: FileStatus, status_updated_at: ?i64,
};
pub fn parse(arena: Allocator, json: []const u8) !?SessionFile;  // 壊れている、または sessionId か pid がなければ null
/// *.json だけを読む。*.key は開かない。読めないファイルは飛ばす。
pub fn scanDir(io: Io, arena: Allocator, dir_path: []const u8) ![]SessionFile;
pub fn displayName(name: ?[]const u8, cwd: ?[]const u8, session_id: []const u8) ![]const u8;

// sources/transcript.zig
pub const Usage = struct { model: []const u8, used: u64 };
pub fn extractUsage(arena: Allocator, tail: []const u8) !?Usage;  // 不完全な先頭行と壊れた行は無視
/// 256 KiB から倍々に広げ、上限 4 MiB で末尾を読む。ファイルがなければ null
pub fn readUsage(io: Io, gpa: Allocator, path: []const u8) !?Usage;
```

- [ ] **Step 1 [Claude]:** テストを書く。
  - `hook_input`：`contracts/fixtures/README.md` の表のとおりに、**すべての `hook-inputs/` を解析**して、`event`、`tool_name`、`notification_type`、`model`、`session_start_source`、`agent_id`、`cwd`、`transcript_path` を確かめる（期待値はテストの中の表）。
    - **プライバシー**：すべての fixture について、`EventRow` のどの文字列にも `CCRAN_SECRET_SENTINEL_` が含まれない。
    - `EventRow` のフィールド名の集合が許可リストと完全に一致する（`@typeInfo`）。
    - `disable_1m` がそのまま入る。`session_id` がない、`hook_event_name` がない、壊れた JSON、空の入力でエラーになる。
  - `session_file`：`fixtures/README.md` の表のとおり。`broken` と空の入力は null。`missing-fields` は `kind=.unknown`、`status=.unknown`。`unknown-fields` も成功する。
    - `displayName`：`name` を優先。`name` がなければ `cwd` の末尾（`/home/demo/project`、`C:\Users\x\プロジェクト\`、末尾の区切りあり）。どちらもなければ `session_id` の先頭 8 文字。
    - `scanDir`：一時ディレクトリに `.json` を 2 つ、壊れたファイル、**`abc.key`（中身は JSON）**、`.txt` を置いて、結果が 2 件。ディレクトリがなければ空。
  - `transcript`：`fixtures/README.md` の表のとおり（8 ファイル）。
    - **`extractUsage` の結果に目印の文字列が含まれない。**
    - 末尾が途中で切れている入力でも動く。先頭行が途中から始まっていても動く。
    - `readUsage`：`last-assistant.jsonl` を読める。**最後の assistant の後に 1 MiB の user 行がある** transcript（テストの中で一時ファイルに生成）でも見つかる。上限の 4 MiB を超えて離れていれば null。ファイルがなければ null。日本語のパスでも読める。
- [ ] **Step 2 [Claude]:** RED を確かめてコミットする（`test(RED): input parsers`）。
- [ ] **Step 3 [User]:** 3 つのファイルを実装する。
- [ ] **Step 4 [Claude]:** GREEN を確かめる。

---

### Task 5: パスとプラットフォーム

**Files:**
- 作成：`monitor/src/paths.zig`、`monitor/src/platform/platform.zig`、`monitor/src/platform/windows.zig`、`monitor/src/platform/macos.zig`（スケルトン）、`monitor/tests/paths_test.zig`、`monitor/tests/platform_test.zig`

**Interfaces:**

```zig
// paths.zig
/// CC_RAN_HOME > Windows: %LOCALAPPDATA%\cc-ran > macOS: $HOME/Library/Application Support/cc-ran
pub fn dataDir(gpa: Allocator, env: *const Environ.Map, os: std.Target.Os.Tag) ![]u8;
/// CLAUDE_CONFIG_DIR/sessions > %USERPROFILE%\.claude\sessions > $HOME/.claude/sessions
pub fn sessionsDir(gpa: Allocator, env: *const Environ.Map, os: std.Target.Os.Tag) ![]u8;

// platform/platform.zig（OS ごとの実装に振り分ける）
pub fn currentPid() !i64;
pub fn isAlive(pid: i64) !bool;
/// Windows: 作成時刻の FILETIME を 10 進の文字列にしたもの。macOS: 形式が未確認なので null
pub fn processStart(gpa: Allocator, pid: i64) !?[]u8;
/// 切り離して起動する。cwd を作業ディレクトリにする。ハンドルは継承しない
pub fn spawnDetached(io: Io, gpa: Allocator, argv: []const []const u8, cwd: []const u8) !void;
```

- フラグと手順は spec §1.3 のとおり（Windows：`DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW`、`bInheritHandles = FALSE`。macOS：`fork` → `setsid` → stdio を `/dev/null` → `chdir` → `exec`）。

- [ ] **Step 1 [Claude]:** テストを書く。
  - `dataDir` と `sessionsDir`：`Environ.Map` を組み立てて、OS ごとの結果、`CC_RAN_HOME` と `CLAUDE_CONFIG_DIR` の優先、環境変数がないときの `error.MissingEnvironment`、日本語を含む値。
  - `platform`（実行中の OS で動かす）：
    - 自分の pid は生きている。
    - `std.process.spawn` で短い子プロセスを起動し、終了を待った後は死んでいる。
    - 使われていない大きな pid は死んでいる。0 と負の pid は死んでいる。
    - Windows：`processStart(self)` が 2 回とも同じで、数字だけで、null ではない。macOS：null でもよい。
    - 死んだ pid の `processStart` は null。
- [ ] **Step 2 [Claude]:** RED を確かめてコミットする（`test(RED): paths and platform`）。
- [ ] **Step 3 [User]:** 実装する。`spawnDetached` の動作は Task 8 のテストで確かめる。
- [ ] **Step 4 [Claude]:** GREEN を確かめる（macOS は CI で確かめる）。

**macOS の `procStart`：** ユーザーの Mac での確認（plan 00 Task 10）が済むまでは null を返す。確認できたら、別のタスクとして追加する。この plan はその確認を待たない。

---

### Task 6: store（SQLite）

**Files:**
- 作成：`monitor/src/store.zig`（スケルトン）、`monitor/tests/store_test.zig`、`monitor/tests/store_concurrency_test.zig`

**Interfaces:**

```zig
pub const Store = struct {
    pub const Mode = enum { read_write_create, read_only };
    pub fn open(path: [:0]const u8, mode: Mode, busy_timeout_ms: i32) !Store;
    pub fn close(self: *Store) void;
    /// WAL に切り替え、BEGIN IMMEDIATE の中で user_version を見て 001_init.sql を適用する
    pub fn ensureSchema(self: *Store) !void;
    pub fn insertEvent(self: *Store, row: EventRow) !void;      // ロックが取れなければ error.Busy
    pub fn eventsAfter(self: *Store, arena: Allocator, seq: i64, limit: u32) ![]StoredEvent;
    pub fn heartbeatAge(self: *Store, now: i64) !?i64;          // heartbeat がなければ null
    pub fn upsertSession(self: *Store, row: SessionRow) !void;
    pub fn deleteSession(self: *Store, session_id: []const u8) !void;
    pub fn loadSessions(self: *Store, arena: Allocator) ![]SessionRow;
    /// 単一起動ロック。記録された daemon が新しければ false
    pub fn tryAcquireDaemonLock(self: *Store, pid: i64, proc_start: ?[]const u8, now: i64) !bool;
    pub fn heartbeat(self: *Store, pid: i64, now: i64) !bool;   // ロックを奪われていたら false
    pub fn lastProcessedSeq(self: *Store) !i64;
    pub fn markProcessed(self: *Store, seq: i64, last_hook_at: ?i64) !void; // last_hook_at があれば hooks_seen = 1
    pub fn pruneEvents(self: *Store, processed_seq: i64, older_than: i64) !void;
    pub fn checkpoint(self: *Store) !void;
    pub fn begin(self: *Store) !void;
    pub fn commit(self: *Store) !void;
    pub fn rollback(self: *Store) void;
};
pub const SessionRow = struct { /* sessions の全列。Task 6 の RED で確定する */ };
```

- [ ] **Step 1 [Claude]:** テストを書く（すべて一時ディレクトリの実ファイルの DB）。
  - `ensureSchema`：`user_version = 1`、`journal_mode = wal`、2 回呼んでも成功する。
  - **VIEW の列**が `contracts/schema/columns.json` と一致する（Zig の側からも検証する）。
  - `insertEvent` → `eventsAfter`：許可リストの全項目が往復する。NULL も往復する。日本語の `cwd` も往復する。`seq` は昇順で、`limit` が効く。
  - 日本語を含む DB のパスで開ける。
  - `upsertSession` → `loadSessions` が往復する。`v_sessions` に出る。`deleteSession` で消える。不正な列挙値は VIEW に出る前に弾かれる。
  - 単一起動ロック：
    - 空なら取れる。
    - 新しい heartbeat があれば別の pid は取れない。
    - 10 秒より古ければ取れる。
    - `heartbeat` は、ロックを奪われた後は false を返す。
  - `heartbeatAge`：なければ null。ある場合は差分。
  - `markProcessed`：`last_hook_at` を渡すと `v_monitor.hooks_seen = 1`。その後イベントを消しても 1 のまま。
  - `pruneEvents`：処理済みで古いものだけを消す。未処理は消えない。
  - `checkpoint` の後に WAL が小さくなる（`TRUNCATE`）。
  - **`Store.Mode.read_only`** で書き込むと失敗する。
  - **ロック中の挙動**：別の接続が `BEGIN IMMEDIATE` を保持している間、`busy_timeout_ms = 50` の `insertEvent` が 300ms 以内に `error.Busy` を返す。
  - **競合**（`store_concurrency_test.zig`）：8 個のスレッドがそれぞれ自分の接続で、**空の DB** に対して `ensureSchema` と `insertEvent` を 50 回ずつ行う（`busy_timeout = 500`、Busy は再試行）。全スレッドが成功し、`COUNT(*) = 400`、`seq` に重複がない。
- [ ] **Step 2 [Claude]:** `SessionRow` の全列をスケルトンに書き、RED を確かめてコミットする（`test(RED): store`）。
- [ ] **Step 3 [User]:** `src/store.zig` を実装する（`sqlite_c.zig` の宣言を使う。足りない宣言は [Claude] に頼むか、追加してよい）。
- [ ] **Step 4 [Claude]:** GREEN を確かめる。

---

### Task 7: daemon の 1 回分の処理（tick）

**Files:**
- 作成：`monitor/src/daemon/tick.zig`（スケルトン）、`monitor/tests/tick_test.zig`

**Interfaces:**

```zig
pub const Prober = struct {            // テストで差し替える
    ctx: *anyopaque,
    isAlive: *const fn (ctx: *anyopaque, pid: i64) bool,
    processStart: *const fn (ctx: *anyopaque, gpa: Allocator, pid: i64) ?[]u8,
};
pub const Context = struct {
    io: Io, gpa: Allocator, store: *Store, sessions_dir: []const u8,
    table: ModelTable, config: *const Config, prober: Prober,
};
/// events の取り込み → セッションファイルの統合 → 生存確認 → reconcile → コンテキスト → 順位 → 削除 → 書き込み
pub fn tick(ctx: *Context, now: i64) !void;
```

**重要な統合の規則：** すべて `session_id` をキーに統合する。`ended` への移行は、(a) `SessionEnd`、または (b) 記録された pid が死んでいる、または `processStart` が非 null で記録と異なる、のいずれか。Hook だけのセッション（pid 不明）は、最後の活動から 24 時間で削除する。

- [ ] **Step 1 [Claude]:** テストを書く。各テストは一時ディレクトリに DB と sessions ディレクトリを作り、イベントを `insertEvent` で入れ、`tick` を呼び、**`v_sessions` を読んで確かめる**。`Prober` は生きている pid の集合を持つ偽物。
  - `Hook_then_file_makes_one_row`、`File_then_hook_makes_one_row`：1 行で、`kind` と `name` はファイルから、`attention` は Hook から。
  - `File_only_session_uses_status`：`busy` → `working`、`idle` → `idle`、未知の `status` → `idle`。
  - `Resume_updates_pid`：同じ `session_id` のファイルが新しい pid で現れる。古い pid は死んでいる。`ended` にならない。
  - `Resume_after_session_end_returns_to_idle`：`SessionEnd` → `SessionStart.resume` で `idle`。
  - `Clear_ends_old_and_starts_new`：同じ pid のまま、`SessionEnd`（古い id）と `SessionStart.clear`（新しい id）で、古い行は `ended`、新しい行は `idle`。
  - `Dead_pid_ends_session`、`Proc_start_mismatch_ends_session`、`Null_proc_start_is_not_a_mismatch`。
  - `Ended_row_is_deleted_after_grace`：299 秒では残り、300 秒で消える。`config.ended_grace_ms` が効く。
  - `Hook_only_session_expires_after_24h`。
  - `Interrupted_turn_reconciles_to_idle`：`UserPromptSubmit` の後、`status=idle` で `statusUpdatedAt` が新しいファイルがあり、3 秒後の tick で `idle`。
  - `Context_comes_from_transcript`：`transcript_path` に `last-assistant.jsonl` のコピーを指定すると、`context_used_tokens = 123456`、`model = claude-opus-5-5`、`window_source = builtin`、`context_level = ok`、`context_ratio` が約 0.123。
  - `Missing_transcript_is_unknown`。
  - `Disable_1m_is_sticky`：`SessionStart` の `disable_1m = true` が後のイベントで消えない。
  - `Display_name_falls_back_to_cwd`。日本語の `cwd` でも末尾が取れる。
  - `Sort_rank_follows_attention`：`working`、`needs_permission`、`done` の 3 セッションで `needs_permission` が 0。
  - `Progress_is_durable`：2 回目の tick で同じイベントを二重に適用しない（`attention_since` が変わらない）。別の `Store` を開き直しても同じ。
  - `Hooks_seen_and_last_hook_at_are_set`。
  - `Old_events_are_pruned`：24 時間より古い処理済みイベントが消える。
  - `Broken_session_file_does_not_stop_tick`。`sessions_dir` がなくても成功する。
  - `Tick_is_atomic`：トランザクションの中で書く（途中のエラーで `last_processed_seq` が進まない）。読み手から見て、半分だけ更新された状態にならない。
- [ ] **Step 2 [Claude]:** RED を確かめてコミットする（`test(RED): daemon tick`）。
- [ ] **Step 3 [User]:** `src/daemon/tick.zig` を実装する。
- [ ] **Step 4 [Claude]:** GREEN を確かめる。

---

### Task 8: CLI（`hook` と `daemon`）

**Files:**
- 作成：`monitor/src/cli.zig`、`monitor/src/commands/hook.zig`、`monitor/src/commands/daemon.zig`（スケルトン）、`monitor/tests/cli_hook_test.zig`、`monitor/tests/cli_daemon_test.zig`
- 変更：`monitor/src/main.zig`（`cli.run` を呼ぶだけ）

**Interfaces:**

```zig
// cli.zig
pub fn run(init: std.process.Init) u8;
// commands/hook.zig：ここからエラーを外に出さない。必ず 0 を返す
pub fn run(init: std.process.Init) u8;
// commands/daemon.zig
pub fn run(init: std.process.Init) u8;
```

- 環境変数 `CC_RAN_DAEMON_MAX_RUNTIME_MS`：設定されていれば、その時間で daemon が正常終了する（テストで使う）。
- hook の処理：stdin を読む → `hook_input.parse` → データディレクトリを作る → `open`（500ms）→ `ensureSchema` → `insertEvent` → `heartbeatAge` が null か 10 秒以上なら `spawnDetached(self, "daemon", cwd = データディレクトリ)`。

- [ ] **Step 1 [Claude]:** テストを書く。**ビルドした `cc-ran` を実際に実行する**（`test_options.cc_ran_exe`、`CC_RAN_HOME` に一時ディレクトリ、`CC_RAN_DAEMON_MAX_RUNTIME_MS=3000`）。
  - `Hook_always_exits_zero_with_empty_stdout`：すべての `hook-inputs/` の fixture で exit 0、stdout が空、stderr が空、`events` に 1 行増える。
  - `Hook_survives_bad_input`：壊れた JSON、空の stdin、`session_id` がない JSON、10 MiB の JSON で exit 0、stdout が空。
  - `Hook_survives_bad_environment`：`CC_RAN_HOME` が作成できない場所（ファイルの下）で exit 0、stdout が空。DB が別の接続でロックされていても 1 秒以内に exit 0。
    - ※ 上の 2 件の exit 0 と stdout の確認は、スケルトンでも通る（ガードのテスト）。
  - **プライバシー**（`Db_and_wal_never_contain_body_text`）：すべての fixture を流した後、DB、`-wal`、`-shm` のバイト列全体に `CCRAN_SECRET_SENTINEL_` が含まれない。`synchronous` や WAL の状態によらないように、最後の hook の直後に読む。
  - `Hook_records_disable_1m`：環境変数 `CLAUDE_CODE_DISABLE_1M_CONTEXT=1` のとき `disable_1m = 1`、ないとき 0。
  - `Hook_respects_non_ascii_home`：`CC_RAN_HOME` が日本語のパスでも動く。
  - `Hook_starts_daemon_when_heartbeat_is_stale`：どのイベント（`PreToolUse`）でも、数秒以内に `v_monitor.daemon_alive = 1` になり、イベントが `sessions` に反映される。
  - `Hook_does_not_start_second_daemon`：heartbeat が新しければ起動しない。**同時に 5 個の hook を動かしても**、`monitor_state.daemon_pid` は 1 つのまま安定する。
  - `Hook_returns_before_daemon_exits`：daemon を起動する hook 自体が 1 秒以内に終わる（stdout のパイプを子プロセスが掴んでいない）。
  - **`Daemon_does_not_hold_project_dir`**（Review Focus 4）：一時的なプロジェクトフォルダを作業ディレクトリにして hook を実行し、daemon が動いている間にそのフォルダを削除できる。
  - `Daemon_exits_when_lock_is_lost`、`Second_daemon_exits_immediately`、`Daemon_writes_heartbeat`、`Daemon_checkpoints_on_exit`。
- [ ] **Step 2 [Claude]:** RED を確かめてコミットする（`test(RED): hook and daemon commands`）。ガードのテスト以外が失敗することを確かめる。
- [ ] **Step 3 [User]:** 実装する。
- [ ] **Step 4 [Claude]:** GREEN を確かめる。性能も測る：`hook` を 20 回実行して中央値が 50ms 未満であることを報告する。

---

### Task 9: `status` と `doctor`

**Files:**
- 作成：`monitor/src/commands/status.zig`、`monitor/src/commands/doctor.zig`（スケルトン）、`monitor/tests/cli_status_test.zig`

**Interfaces:** `pub fn run(init: std.process.Init) u8;`（それぞれ）

- [ ] **Step 1 [Claude]:** テストを書く（実際に実行する）。
  - `status`：DB を用意して、セッションの `display_name`、`attention`、コンテキストの % が `sort_rank` の順に出る。fallback は「推定」と出る。DB がなければ「データなし」と案内して exit 0。**DB を作らない。** 日本語の名前も文字化けしない。
  - `doctor`：
    - データディレクトリ、DB の書き込み可否、daemon の生存、`hooks_seen`、最後に Hook を受け取った時刻を出す。
    - PATH に `cc-ran` がなければそれを指摘する。
    - **何も修正しない**：実行前後で DB のバイト列が変わらない（DB がなければ作らない）。
    - `hooks_seen = 0` のときプラグインの導入手順を案内する。
  - 不明なサブコマンドと引数なしは、使い方を stderr に出して exit 1（設定ミスで Claude をブロックしないよう、2 は使わない）。
- [ ] **Step 2 [Claude]:** RED を確かめてコミットする（`test(RED): status and doctor`）。
- [ ] **Step 3 [User]:** 実装する。
- [ ] **Step 4 [Claude]:** GREEN を確かめる。

---

### Task 10: リリースと E2E（GREEN なし）

**Files:**
- 作成：`.github/workflows/release.yml`（`monitor/v*` の部分）
- 変更：`README.md`（インストール手順。PATH の追加を含む）

- [ ] **Step 1 [Claude]:** `release.yml` を書く。タグ `monitor/v*` で `ReleaseSafe` のバイナリを 2 ターゲット作り、`cc-ran-<ver>-windows-x64.zip` と `cc-ran-<ver>-macos-arm64.zip` にまとめて Release に添付する。**タグの push はユーザーが行う。**
- [ ] **Step 2 [Claude]:** README にインストール手順を書く（spec §6.1、§10.4）。
- [ ] **Step 3 [User]:** Windows で E2E を行う（spec §8.4）。`cc-ran` を PATH に置き、`/plugin marketplace add` と `/plugin install` で導入して、`cc-ran status` で次を確かめる。
  - **承認待ち：** `Write` で新しいファイルを作らせるなど、確実にダイアログが出る操作をする。すぐ `needs_permission` になる。**ダイアログの表示中のセッションファイルの `status` も記録する**（spec §3.2 の `needs_*` の補正を決めるため）。
  - 許可すると `working` に戻る。拒否すると解除される。
  - 通常の応答の後に `done`、次の入力で `working`。
  - **Esc で中断すると、数秒で `idle` になる。**
  - **Esc で承認ダイアログを閉じたときの状態を記録する。**
  - `/clear` と `/resume` で行が重複しない。
  - `/exit` の後に `ended` になり、5 分後に消える。ターミナルを閉じても daemon が残る。
  - daemon のプロセスを kill すると、作業中のセッションの次の Hook で復旧する。
  - セッション 2〜3 個を並べて、並列のサブエージェントの承認待ちが消えない。
- [ ] **Step 4 [Claude]:** E2E の結果を findings に記録する。問題があれば、テストを追加して（RED）、ユーザーに渡す。
- [ ] **Step 5 [User]:** 手元の Mac で同じ確認の主要部分を行う（plan 00 Task 10 の `procStart` の確認も一緒に）。
