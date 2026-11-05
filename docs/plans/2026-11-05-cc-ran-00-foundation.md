# cc-ran 00 — 基盤（初期化・契約・検証）実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans で実行する。各ステップには担当（**[Claude]** / **[User]**）を付けてある。**[User]** のステップに来たら、必ずそこで止まり、ユーザーから完了の連絡を受けてから再開する。subagent-driven は使わない（GREEN をユーザーが担当するため）。チェックボックスは `- [ ]` 形式。

**Goal:** monitor と UI のどちらの実装（plan 01 / 02）も始められるようにする。そのために、ツールチェーン、モノレポの骨組み、`contracts/`、プラグイン、CI を揃え、spec §12 の検証項目をすべて片付ける。

**Architecture:**
- monorepo に、独立したプロジェクトを 2 つ（`monitor/` は Zig、`ui/avalonia/` は .NET）置き、両者をつなぐのは `contracts/` だけにする。
- この plan ではプロダクトのロジックを書かない。
- 検証用のコードは `spikes/` に置き、結果を記録したら削除する。

**Tech Stack:** Zig 0.17.1、SQLite amalgamation（同梱）、.NET 10 SDK、Avalonia 12.1.x、xUnit v3（Avalonia 12 のヘッドレステストは xUnit v3 が対象）、Microsoft.Data.Sqlite、GitHub Actions、Claude Code プラグイン

**Spec:** `docs/specs/2026-11-05-cc-ran-design.md`

**後続の plan:**
- `docs/plans/2026-11-05-cc-ran-01-monitor.md`
- `docs/plans/2026-11-05-cc-ran-02-ui.md`

どちらも、この plan の Task 11 を終えてから書く。I/O まわりのシグネチャを、インストールした Zig 0.17.1 の `lib/std` で確かめてから決めるため。

## Global Constraints

### ツールチェーンと対象プラットフォーム

- Zig は **0.17.1** に固定する（`build.zig.zon` の `minimum_zig_version = "0.17.1"`、CI も同じバージョン）。
- .NET は **10** の SDK を `ui/avalonia/global.json` で固定する。Avalonia は **12.1.x**、テストフレームワークは xUnit v3 とし、バージョンは `Directory.Packages.props` で一元管理する。
- 対象は **Windows x64** と **macOS arm64** だけ。Intel Mac、Windows ARM64、Linux は対象外。

### 名前と保存場所

- バイナリ名は、監視側が `cc-ran`、UI 側が `cc-ran-ui`。
- データディレクトリ：
  - Windows：`%LOCALAPPDATA%\cc-ran\`
  - macOS：`~/Library/Application Support/cc-ran/`
  - 環境変数 `CC_RAN_HOME` で上書きできる。
- DB ファイルは `cc-ran.db`（WAL）、設定ファイルは `config.json`。
- 時刻はすべて UTC の epoch ミリ秒（INTEGER）で持つ。`contract_version` は `1.0`。

### 守るべきこと（安全とプライバシー）

- **Claude Code の設定ファイル（`settings.json` など）を書き換えない。`~/.claude` の中に書き込まない。`~/.claude/sessions/*.key` を読まない。**
- 保存してよい項目は spec §2.1 の許可リストのものだけ：`hook_event_name`、`session_id`、受信時刻、`cwd`、`transcript_path`、`tool_name`、`notification_type`、`model`、`disable_1m`。本文は保存しない。
- `cc-ran hook` は**常に exit 0 で終わり、stdout には何も出さない**。

### 役割分担とコードの置き場所

- **[Claude]** が書いてよいもの：テスト、コンパイルが通るだけのスケルトン（`error.NotImplemented` / `throw new NotImplementedException()`）、ビルド設定、CI、`contracts/`、プラグインのマニフェスト、FFI の宣言（`extern`）。
- **[User]** が書くもの：`src/` にあるロジック。
- spike のコードはプロダクトコードではない。`spikes/` の外に移さず、Task 11 で削除する。

### Zig の規約（plan 01 にも引き継ぐ）

- テストは `monitor/tests/` に別ファイルとして置く。`build.zig` でモジュールとして import する。`src/` の中には `test` ブロックを書かない。こうすると、RED のコミットと GREEN のコミットが同じファイルに触れずに済む。
- スケルトンとして公開する部分は `pub` にする。使わない引数には `_ = param;` を付ける。
- 各テストファイルで `std.testing.refAllDecls` を呼び、どこからも参照されていないスケルトンも型検査されるようにする。

### リポジトリの規約

- fixtures と SQL の改行コードは LF に固定する（`.gitattributes`）。
- コミットメッセージの末尾には次の行を付ける：`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## Review Focus

この 5 つは、spec が前提にしているのに、この plan のテストでは確かめていない入力条件。テストは、それぞれ担当する plan のタスクに入れる（この plan ではテストを書かない）。

1. **DB がまだない状態で UI を起動する**
   - `Mode=ReadOnly` で存在しないファイルを開くと例外になる。
   - 期待する動作：クラッシュせず、空の一覧と「監視停止中」のバナーを出す。UI は DB を作らない。
   - 担当：plan 02（DB リーダー）。
2. **`--resume` でセッションを再開する**
   - 同じ `session_id` が、新しい pid と新しいセッションファイルで戻ってくる。
   - 期待する動作：pid を更新する。古い pid が死んだことを理由に `ended` にはしない。
   - 担当：plan 01（reducer / daemon の統合）。
3. **同じプロセスの中で `/clear` などにより新しいセッションが始まる**
   - pid は同じで、`session_id` だけが新しくなる。
   - 期待する動作：古いセッションを `ended` にし、300 秒の猶予期間のあいだ一覧に残し続けない。
   - 担当：plan 01。
4. **Hook とセッションファイルのどちらが先に来ても扱える**
   - 期待する動作：`session_id` をキーにまとめ、重複した行を作らない。
   - 担当：plan 01。
5. **パスに ASCII 以外の文字が含まれる**
   - 日本語のユーザー名や `cwd` を、Win32 API（UTF-16）、transcript のパス、SQLite の open で正しく扱える。
   - 担当：この plan の Task 7（spike で確認）と、plan 01（platform のテスト）。

---

### Task 1: ツールチェーンを入れる（spec §12-1）

**Files:** なし（開発マシンの環境だけを変える）

**Interfaces:**
- Produces：PATH 上で `zig version` が `0.17.1` を返し、`dotnet --list-sdks` に `10.0.x` が含まれる状態。

- [ ] **Step 1 [Claude]:** 今の配置を確認する。
  - 実行：`where.exe zig; zig version; dotnet --list-sdks; winget --version`
  - 期待：Zig は 0.15.1、.NET SDK は 8.0.x だけ。それぞれのインストール方法（winget、手動の zip、scoop など）を特定する。
- [ ] **Step 2 [Claude]:** 更新の手順をユーザーに提示する。
  - Zig 0.17.1 は、今と同じ方式で入れ替える。zip を使う場合は `https://ziglang.org/download/index.json` の `0.17.1.x86_64-windows` の URL と shasum を使う。
  - .NET は `winget install Microsoft.DotNet.SDK.10`。
  - ZLS 0.17.0 を入れるかどうかもユーザーに尋ねる。
  - **PATH の変更とインストールは、ユーザーの承認を得てから行う。**
- [ ] **Step 3 [User]:** 承認する（または自分で入れる）。
- [ ] **Step 4 [Claude]:** 確認する。
  - 実行：`zig version; dotnet --list-sdks`
  - 期待：`0.17.1`、および `10.0.` で始まる行がある。

---

### Task 2: モノレポの骨組み

**Files:**
- 作成：
  - リポジトリ直下：`.gitattributes`、`README.md`
  - monitor：`monitor/build.zig`、`monitor/build.zig.zon`、`monitor/src/main.zig`、`monitor/tests/smoke_test.zig`
  - UI：`ui/avalonia/global.json`、`ui/avalonia/Directory.Packages.props`、`ui/avalonia/Directory.Build.props`、`ui/avalonia/CcRan.Ui.slnx`
  - UI のプロジェクトファイル：`ui/avalonia/src/CcRan.Ui/CcRan.Ui.csproj`（`App.axaml`、`Program.cs` も同じ場所）、`ui/avalonia/src/CcRan.Ui.Core/CcRan.Ui.Core.csproj`、`ui/avalonia/tests/CcRan.Ui.Core.Tests/CcRan.Ui.Core.Tests.csproj`、`ui/avalonia/tests/CcRan.Ui.Tests/CcRan.Ui.Tests.csproj`
- 変更：`.gitignore`

**Interfaces:**
- Produces（`monitor/`）
  - `zig build` で `zig-out/bin/cc-ran(.exe)` ができる。
  - `zig build test` が `monitor/tests/*.zig` を実行する。
  - 引数 `-Dtarget=aarch64-macos` を受け付ける。
- Produces（`ui/avalonia/`）
  - `dotnet build` と `dotnet test` が通る。
  - `CcRan.Ui` のアセンブリ名は `cc-ran-ui`。
  - `CcRan.Ui.Core` は Avalonia を参照しない。
  - `CcRan.Ui.Tests` は Avalonia.Headless.XUnit を使い、`[assembly: AvaloniaTestApplication(...)]` を宣言する。
- Produces（共通）：`.gitattributes` で `contracts/** text eol=lf`、`*.sql text eol=lf`、`*.jsonl text eol=lf`、`*.json text eol=lf` を指定する。

- [ ] **Step 1 [Claude]:** 作業用のブランチ `chore/scaffold` を切る。
- [ ] **Step 2 [Claude]:** `.gitattributes` と `.gitignore` を作る。
  - `.gitignore` に追加するもの：`monitor/.zig-cache/`、`monitor/zig-out/`、`**/bin/`、`**/obj/`、`*.db`、`*.db-wal`、`*.db-shm`、`spikes/**/zig-out/`、`spikes/**/.zig-cache/`
- [ ] **Step 3 [Claude]:** `monitor/` の骨組みを作る。
  - `build.zig.zon`：`.name = .cc_ran`、`minimum_zig_version = "0.17.1"`、依存なし。
  - `build.zig`：`b.addExecutable(.{ .name = "cc-ran", .root_module = b.createModule(.{ .root_source_file = b.path("src/main.zig"), .target = target, .optimize = optimize }) })`。test ステップでは `tests/` のファイルを `b.addTest` で 1 つずつ登録する。
  - `src/main.zig`：`pub fn main(init: std.process.Init) !void { _ = init; }` だけ。サブコマンドの振り分けは plan 01 でユーザーが実装する。
  - `tests/smoke_test.zig`：`test "smoke" { try std.testing.expect(true); }`
- [ ] **Step 4 [Claude]:** 確認する。
  - 実行：`cd monitor; zig build; zig build test; zig build -Dtarget=aarch64-macos`
  - 期待：3 つとも exit 0。`zig-out/bin/` に `cc-ran.exe` と `cc-ran`（Mach-O）ができる。Mach-O かどうかは `file` コマンドか先頭バイト `cf fa ed fe` で確かめる。
- [ ] **Step 5 [Claude]:** `ui/avalonia/` の骨組みを作る。
  - `global.json`：`{"sdk":{"version":"10.0.100","rollForward":"latestFeature"}}`。`version` は、実際に入っている SDK のバージョンに合わせる。
  - `Directory.Packages.props`：`ManagePackageVersionsCentrally=true`。Avalonia、Avalonia.Desktop、Avalonia.Themes.Fluent、Avalonia.Headless.XUnit は **12.1 系の最新パッチ**に揃える。Microsoft.Data.Sqlite、xunit.v3、Microsoft.NET.Test.Sdk も最新の安定版にする。バージョンは `dotnet package search <id> --exact-match` で確かめて固定する。
  - `Directory.Build.props`：`TargetFramework=net10.0`、`Nullable=enable`、`TreatWarningsAsErrors=true`
  - `CcRan.Ui`：`OutputType=WinExe`、`AssemblyName=cc-ran-ui`。空のウィンドウを開くだけの `App` と `Program` を置く（Avalonia の雛形と同じ最小構成）。
- [ ] **Step 6 [Claude]:** 確認する。
  - 実行：`cd ui/avalonia; dotnet build; dotnet test`
  - 期待：ビルドは成功。テストは両方のプロジェクトで 0 件か、smoke の 1 件だけで、失敗は 0 件。
- [ ] **Step 7 [Claude]:** `README.md` を作る。内容は、プロジェクトの概要、spec へのリンク、`monitor/` と `ui/avalonia/` それぞれのビルドとテストのコマンド。
- [ ] **Step 8 [Claude]:** コミットする（`chore: scaffold monorepo (monitor, ui/avalonia)`）。main へのマージはユーザーの確認を取ってから行う。

---

### Task 3: 契約のスキーマ（`contracts/schema/`）

**Files:**
- 作成：
  - `contracts/schema/001_init.sql`、`contracts/schema/columns.json`、`contracts/schema/CONTRACT.md`、`contracts/README.md`
  - `ui/avalonia/tests/CcRan.Ui.Core.Tests/Contract/ContractSchemaTests.cs`

**Interfaces:**
- Produces：テーブル、VIEW、列、制約。plan 01 と plan 02 は、ここで決めたものをそのまま使う。
  - `events`：`seq INTEGER PRIMARY KEY AUTOINCREMENT`、`received_at INTEGER NOT NULL`、`origin TEXT NOT NULL CHECK(origin IN ('local','cloud'))`、`source TEXT NOT NULL`、`session_id TEXT NOT NULL`、`event TEXT NOT NULL`、`cwd TEXT`、`transcript_path TEXT`、`tool_name TEXT`、`notification_type TEXT`、`model TEXT`、`disable_1m INTEGER CHECK(disable_1m IN (0,1))`
    - `event` には CHECK 制約を付けない。将来イベントが増えても、hook が INSERT に失敗しないようにするため。
  - `sessions`：主キーは `session_id`。列は spec §5.3 のとおり。
    - `attention`、`kind`、`context_level`、`window_source`、`origin` には CHECK 制約を付ける。
    - **猶予期間を過ぎた `ended` の行は daemon が DELETE する。** そのため VIEW には時刻による絞り込みを入れない。
  - `monitor_state`：**1 行だけのテーブル**（`id INTEGER PRIMARY KEY CHECK(id=1)`）。spec §5.3 では key/value と書いたが、VIEW を単純にするためにこの形に変える。
    - 列：`contract_version TEXT NOT NULL`、`daemon_pid INTEGER`、`daemon_proc_start TEXT`、`daemon_heartbeat_at INTEGER`、`daemon_stale_ms INTEGER NOT NULL DEFAULT 10000`、`last_processed_seq INTEGER NOT NULL DEFAULT 0`、`hooks_seen INTEGER NOT NULL DEFAULT 0`、`last_hook_at INTEGER`
    - 初期データとして `INSERT OR IGNORE` で `(1, '1.0', ...)` の 1 行を入れる。
  - `v_sessions`：spec §5.4 の 15 列。`sessions` から SELECT するだけ。
  - `v_monitor`：spec §5.4 の 4 列。
    - `daemon_alive` は `CASE WHEN daemon_heartbeat_at IS NOT NULL AND (CAST(unixepoch('subsec')*1000 AS INTEGER) - daemon_heartbeat_at) <= daemon_stale_ms THEN 1 ELSE 0 END` で求める。
    - `unixepoch('subsec')` には SQLite 3.42 以降が必要。
  - SQL ファイル全体を **何度実行しても同じ結果になる**ようにする（`CREATE ... IF NOT EXISTS`）。最後に `PRAGMA user_version = 1;` を置く。
  - `columns.json` の形式：`{"contract_version":"1.0","views":{"v_sessions":[{"name":"session_id","type":"TEXT","nullable":false}, ...],"v_monitor":[...]}}`
- Consumes：なし

- [ ] **Step 1 [Claude]:** ブランチ `feat/contracts-schema` を切る。
- [ ] **Step 2 [Claude]:** 契約のテストを書く。
  - ファイル：`ContractSchemaTests.cs`
  - リポジトリのルートは、`.git` を親ディレクトリへたどって見つける。
  - テストの中身：
    - `Schema_applies_to_empty_db`：インメモリ DB に `001_init.sql` を流すと例外が出ず、`PRAGMA user_version` が `1` になる。
    - `Schema_is_idempotent`：2 回流しても例外が出ない。
    - `View_columns_match_columns_json`：`v_sessions` と `v_monitor` それぞれについて、`pragma_table_xinfo('<view>')` で取った列名の並びが `columns.json` と完全に一致する。
    - `Monitor_view_has_single_row_with_contract_1_0`：`SELECT contract_version, daemon_alive, hooks_seen FROM v_monitor` の結果が `("1.0", 0, 0)` の 1 行になる。
    - `Sessions_reject_unknown_attention`：`attention='bogus'` の INSERT が `SqliteException` になる。
    - `Events_accept_unknown_event_name`：`event='FutureEvent'` の INSERT が成功する。
- [ ] **Step 3 [Claude]:** テストを実行して、失敗することを確かめる。
  - 実行：`dotnet test --filter FullyQualifiedName~Contract`
  - 期待：まだ SQL ファイルがないので、全件 FAIL（ファイルが見つからない）になる。
- [ ] **Step 4 [Claude]:** `001_init.sql`、`columns.json`、`CONTRACT.md` を書く。
  - `CONTRACT.md` に書くこと：各列の意味、列挙値、バージョンの規則（minor は列の追加、major は列の削除や意味の変更。UI は major が一致するときだけ表示する）。
  - これらは spec 上 Claude が書く契約の成果物で、ユーザーの GREEN ではない。
- [ ] **Step 5 [Claude]:** もう一度テストを実行する。
  - 実行：同上
  - 期待：全件 PASS。
  - Microsoft.Data.Sqlite に同梱されている SQLite が 3.42 より古くて `unixepoch('subsec')` が使えない場合は、`(julianday('now') - 2440587.5)*86400000` に置き換える。どちらを使ったかを `CONTRACT.md` に記録する。
- [ ] **Step 6 [Claude]:** コミットする（`feat(contracts): schema v1 (tables, v_sessions, v_monitor)`）。

---

### Task 4: モデル表と入力の fixtures

**Files:**
- 作成：
  - `contracts/models.json`
  - `contracts/fixtures/hook-inputs/*.json`
  - `contracts/fixtures/session-files/*.json`
  - `contracts/fixtures/transcripts/*.jsonl`
  - `contracts/fixtures/README.md`
  - `ui/avalonia/tests/CcRan.Ui.Core.Tests/Contract/ContractFixtureTests.cs`

**Interfaces:**
- Produces：`models.json` の形式。

  ```json
  {"version":1,"verified_at":"2026-11-05","sources":["https://code.claude.com/docs/en/model-config","claude-api skill shared/models.md (2026-10-06)"],"default_window":200000,"one_million":1000000,"models":[{"prefix":"claude-opus-5-5","window":1000000}, ...]}
  ```

  - 照合のしかたは、日付の接尾辞を外したモデル ID に対して、`prefix` が**最も長く一致するもの**を選ぶ。
  - 中身は spec §4.3 の表をすべて載せる。`claude-opus-4-6` と `claude-sonnet-4-6` は 200000、`claude-haiku-4-5` は 200000 にする。
- Produces：fixture のファイル名の規則。
  - `hook-inputs/<Event>[.<variant>].json`：例 `Notification.permission_prompt.json`、`PreToolUse.json`
  - `session-files/<case>.json`：例 `interactive-busy.json`、`bg-idle.json`、`unknown-fields.json`、`missing-fields.json`
  - `transcripts/<case>.jsonl`：例 `last-assistant.jsonl`、`sidechain-last.jsonl`、`synthetic-last.jsonl`、`broken-line.jsonl`、`no-assistant.jsonl`
- Produces：本文を表す項目（`prompt`、`tool_input`、`tool_response`、`last_assistant_message`、`message`、`error`）には、**目印の文字列 `CCRAN_SECRET_SENTINEL_<n>`** を入れる。これは plan 01 のプライバシーテストで使う。
- Produces：`fixtures/README.md` に、fixture ごとの「期待される抽出結果」を表にして書く。たとえば `last-assistant.jsonl` からは `model=claude-opus-5-5`、`used=123456` が抽出される、といった具合。plan 01 のテストはこの表の値を使う。
- Consumes：なし

- [ ] **Step 1 [Claude]:** 公式ドキュメントで、Hook の入力の形を確かめる。
  - 参照：`https://code.claude.com/docs/en/hooks`
  - 確かめること：spec §6.2 のイベントそれぞれについて、共通の項目と、イベント固有の項目（`notification_type` の列挙値、`model` など）。
  - **実際の Hook の出力を読む必要はない**（プラグインはまだ入れていない）。
- [ ] **Step 2 [Claude]:** セッションファイルのキーの構成を確かめる。
  - 実行：`~/.claude/sessions/*.json` について、**キーの名前と値の型だけ**を出す小さなスクリプトをスクラッチパッドで動かす。値そのものは出さない。`*.key` は対象にしない。
  - そのうえで、名前とパスをダミーに置き換えた fixture を作る。
- [ ] **Step 3 [Claude]:** テストを書く。
  - ファイル：`ContractFixtureTests.cs`
  - テストの中身：
    - `All_json_fixtures_parse`：`hook-inputs/` と `session-files/` の JSON が `System.Text.Json` で読める。
    - `All_jsonl_fixtures_parse_except_broken`：`broken-line.jsonl` 以外のすべての行が読める。
    - `Hook_inputs_cover_subscribed_events`：spec §6.2 の 13 イベントそれぞれについて、fixture が 1 つ以上ある。
    - `Hook_inputs_have_required_fields`：すべてに `session_id` と `hook_event_name` がある。
    - `Models_json_has_all_spec_models`：spec §4.3 で名前が挙がっている 14 モデルについて、prefix と window が期待どおり。「それより古いモデル」は `default_window` で扱う。
    - 14 モデルの正確な API ID（例：`claude-fable-5-1`）は、claude-api skill の `shared/models.md` で確かめてから書く。
    - `Fixtures_use_lf_only`：fixtures のバイト列に `\r` が含まれない。
- [ ] **Step 4 [Claude]:** テストを実行して、失敗することを確かめる。
  - 実行：`dotnet test --filter FullyQualifiedName~ContractFixture`
  - 期待：fixture がまだないので FAIL。
- [ ] **Step 5 [Claude]:** `models.json`、fixtures、`fixtures/README.md` を作る。
- [ ] **Step 6 [Claude]:** もう一度テストを実行する。
  - 実行：同上
  - 期待：全件 PASS。
- [ ] **Step 7 [Claude]:** コミットする（`feat(contracts): models table and input fixtures`）。

`scenarios/` と `db-seeds/` は、ここでは作らない。それを使う RED テストと一緒に、plan 01 と plan 02 で作る。形式は、それぞれの plan で決める。

---

### Task 5: プラグインとローカル marketplace

**Files:**
- 作成：`.claude-plugin/marketplace.json`、`plugin/.claude-plugin/plugin.json`、`plugin/hooks/hooks.json`、`plugin/README.md`

**Interfaces:**
- Produces：プラグインを `/plugin install cc-ran@cc-ran` で入れられる。
  - marketplace の名前は `cc-ran`、プラグインの名前は `cc-ran`。
  - `hooks.json` では、spec §6.2 の 13 イベントすべてについて、`{"type":"command","command":"cc-ran hook","timeout":5}` を設定する。matcher は全件にし、`async` は付けない。
- Consumes：なし

- [ ] **Step 1 [Claude]:** 公式ドキュメントで、`plugin.json`、`marketplace.json`、`hooks.json` のスキーマを確かめる。
  - 参照：`https://code.claude.com/docs/en/plugins`、`.../plugin-marketplaces`、`.../plugins-reference`
  - あわせて確かめること：matcher を省略したときの意味、PermissionRequest と Notification の matcher の扱い。
- [ ] **Step 2 [Claude]:** 3 つのファイルを書く。
- [ ] **Step 3 [Claude]:** 検証する。
  - 実行：`claude plugin validate ./plugin` と `claude plugin validate .`（コマンドがなければ、ドキュメントのスキーマと突き合わせて確認する）
  - 期待：エラーなし。
- [ ] **Step 4 [Claude]:** `plugin/README.md` を書く。内容は、導入の手順（spec §6.1）と、cc-ran が設定ファイルを書き換えないことの説明。
- [ ] **Step 5 [Claude]:** コミットする（`feat(plugin): hooks plugin and local marketplace`）。

**まだ有効にしない**。有効にするのは Task 9 で spike 用のスタブを使うときだけ。

---

### Task 6: GitHub リモートと CI

**Files:**
- 作成：`.github/workflows/monitor.yml`、`.github/workflows/ui.yml`

**Interfaces:**
- Produces（`monitor.yml`）
  - 起動条件：`push` / `pull_request` で `monitor/**`、`contracts/**`、ワークフロー自身のファイルが変わったとき。
  - ジョブ：`windows-latest` と `macos-latest` のマトリクスで `zig build test`。ubuntu で `zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe` と `-Dtarget=x86_64-windows` を作り、artifact としてアップロードする。
  - Zig のセットアップ：`mlugg/setup-zig`（バージョンタグを固定）に `version: 0.17.1` を指定する。
- Produces（`ui.yml`）
  - 起動条件：`ui/**`、`contracts/**`、ワークフロー自身のファイルが変わったとき。
  - ジョブ：`windows-latest` と `macos-latest` で `actions/setup-dotnet`（`global-json-file: ui/avalonia/global.json`）を使い、`dotnet test`。
- Consumes：Task 2 のビルドコマンドと、Task 3・4 の契約テスト。

- [ ] **Step 1 [Claude]:** ワークフローを 2 つ書く。アクションはメジャーバージョンのタグで固定する。
- [ ] **Step 2 [User]:** GitHub にリポジトリを作る（公開か非公開か、名前を決める）。リモートの URL を Claude に伝え、**push を許可する**。push は外部に公開する操作なので、この許可がない限り Claude は push しない。
- [ ] **Step 3 [Claude]:** リモートを追加し、`main` と作業ブランチを push する。
- [ ] **Step 4 [Claude]:** 確認する。
  - 実行：`gh run list --limit 5` と `gh run watch`
  - 期待：`monitor` と `ui` の両方のワークフローが、Windows と macOS で success になる。mac の Mach-O の artifact がアップロードされている。
- [ ] **Step 5 [Claude]:** コミットする（`ci: monitor and ui workflows`）。`release.yml` は plan 01 と plan 02 の最後に追加する。

---

### Task 7: spike — Zig 0.17 + SQLite + クロスコンパイル（spec §12-2、Review Focus 5）

**Files:**
- 作成（spike、Task 11 で削除する）：`spikes/zig-sqlite/build.zig`、`spikes/zig-sqlite/build.zig.zon`、`spikes/zig-sqlite/src/main.zig`、`.github/workflows/spikes.yml`（`workflow_dispatch` で起動）
- 作成（**残すもの**）：`monitor/vendor/sqlite/sqlite3.c`、`monitor/vendor/sqlite/sqlite3.h`、`monitor/vendor/sqlite/VERSION.md`、`monitor/src/store/sqlite_c.zig`
- 変更：`monitor/build.zig`（amalgamation を組み込む）

**Interfaces:**
- Produces：`monitor/src/store/sqlite_c.zig` に、SQLite の C API を `extern` で宣言する。**宣言だけで、ラッパーのロジックは書かない。** ラッパー（`store`）はユーザーが plan 01 で書く。
  - 宣言する関数：`sqlite3_open_v2`、`sqlite3_close_v2`、`sqlite3_exec`、`sqlite3_prepare_v2`、`sqlite3_bind_int64`、`sqlite3_bind_text`、`sqlite3_bind_null`、`sqlite3_step`、`sqlite3_column_int64`、`sqlite3_column_text`、`sqlite3_column_type`、`sqlite3_finalize`、`sqlite3_reset`、`sqlite3_busy_timeout`、`sqlite3_errmsg`、`sqlite3_wal_checkpoint_v2`、`sqlite3_free`
  - 定数：`SQLITE_OK`、`SQLITE_ROW`、`SQLITE_DONE`、`SQLITE_BUSY`、`SQLITE_OPEN_READWRITE`、`SQLITE_OPEN_CREATE`、`SQLITE_OPEN_READONLY`、`SQLITE_OPEN_FULLMUTEX`、`SQLITE_TRANSIENT`
- Produces：`monitor/build.zig` で `exe.root_module.addCSourceFile(.{ .file = b.path("vendor/sqlite/sqlite3.c"), .flags = &.{ "-DSQLITE_DQS=0", "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION" } })` と `link_libc = true` を設定する。テスト用のモジュールにも同じ設定をする。
- Consumes：Task 2 の `monitor/build.zig`

- [ ] **Step 1 [Claude]:** SQLite を取得する。
  - `https://sqlite.org/download.html` から最新の amalgamation を取得し、SHA3-256 を照合する。
  - `monitor/vendor/sqlite/` に置き、`VERSION.md` にバージョン、URL、ハッシュを記録する。
- [ ] **Step 2 [Claude]:** spike のプログラムを書く。
  - 動作：
    1. 引数で受け取ったパスに DB を作る。
    2. WAL にして、`busy_timeout` を 500 にする。
    3. `001_init.sql` を流す。
    4. `events` に 1 行を INSERT して読み戻す。
    5. 経過時間を stderr に出す。
  - 書くのは spike のディレクトリだけで、`monitor/src` には持ち込まない。
- [ ] **Step 3 [Claude]:** Windows で確かめる。
  - 実行：spike のディレクトリで `zig build run -- "<scratchpad>\日本語パス\t.db"`
  - 期待：exit 0。読み戻した値が一致する。プロセスの起動から終了までが 50ms 未満（10 回の中央値）。日本語を含むパスで DB ファイルが作られる。
- [ ] **Step 4 [Claude]:** クロスコンパイルを確かめる。
  - 実行：`zig build -Dtarget=aarch64-macos -Doptimize=ReleaseSafe`
  - 期待：Mach-O arm64 の実行ファイルができる。
- [ ] **Step 5 [Claude]:** macOS の runner で動かす。
  - `spikes.yml` に、macOS の runner でこのバイナリを実行するジョブを追加する。日本語を含む一時パスを使う。
  - 実行：`gh workflow run spikes.yml -f spike=zig-sqlite`、続けて `gh run watch`
  - 期待：success。
- [ ] **Step 6 [Claude]:** `sqlite_c.zig` と `monitor/build.zig` を変更する。
  - `monitor/tests/sqlite_link_test.zig` を追加する。中身は「`sqlite3_open_v2(":memory:")` が `SQLITE_OK` を返す」だけのリンク確認。
  - 実行：`cd monitor; zig build test; zig build -Dtarget=aarch64-macos`
  - 期待：PASS し、ビルドも成功する。
- [ ] **Step 7 [Claude]:** 結果を `docs/specs/2026-11-05-cc-ran-findings.md`（新規）の §12-2 に記録し、コミットする（`chore(monitor): vendor sqlite and C declarations; spike zig-sqlite`）。

---

### Task 8: spike — Native AOT（spec §12-3）

**Files:**
- 作成（spike）：`spikes/aot/AotProbe/AotProbe.csproj`、`spikes/aot/AotProbe/Program.cs`、`spikes/aot/AotTray/`（Avalonia の最小構成のトレイアプリ）。`.github/workflows/spikes.yml` にジョブを追加する。

**Interfaces:**
- Produces：記録として、次の 3 つが Native AOT で動くかどうか。
  - Microsoft.Data.Sqlite で `Mode=ReadOnly` で開くこと、`PRAGMA data_version` を読むこと、存在しないファイルを開いたときの例外の型（Review Focus 1 で使う）。
  - Avalonia 12 の TrayIcon と NativeMenu。
- Consumes：Task 3 の `001_init.sql`

- [ ] **Step 1 [Claude]:** `AotProbe` を書く。
  - 動作：
    1. 引数で受け取った DB を `Mode=ReadOnly` で開く。
    2. `SELECT * FROM v_monitor` と `PRAGMA data_version` を出力する。
    3. 存在しないパスで開いたときの例外の型と `SqliteErrorCode` を出力する。
- [ ] **Step 2 [Claude]:** Windows で AOT ビルドして動かす。
  - 実行：`dotnet publish -r win-x64 -c Release -p:PublishAot=true`。DB は Task 7 の spike で作ったものを使う。
  - 期待：トリミングの警告で失敗しない。出力に `1.0` と data_version が含まれ、例外の型が分かる。
- [ ] **Step 3 [Claude]:** `AotTray` を書く。
  - 中身：Avalonia の最小構成で、TrayIcon と、NativeMenu の「終了」だけ。
  - 実行：`dotnet publish -r win-x64 -p:PublishAot=true`
  - 期待：ビルドが成功する。
- [ ] **Step 4 [User]:** Windows で `AotTray` を起動し、トレイにアイコンが出ること、メニューの「終了」で終わることを目で見て確かめる。
- [ ] **Step 5 [Claude]:** `spikes.yml` に osx-arm64 の AOT publish を追加して実行する。
  - 期待：`AotProbe` が macOS の runner で動き、出力が Windows と同じになる。`AotTray` のビルドが成功する。
- [ ] **Step 6 [Claude]:** 結果を findings の §12-3 に記録してコミットする。

---

### Task 9: spike — Hook の呼び出しと、切り離した daemon（spec §12-4、§12-6）

**Files:**
- 作成（spike）：`spikes/hookprobe/build.zig`、`spikes/hookprobe/build.zig.zon`、`spikes/hookprobe/src/main.zig`

**Interfaces:**
- Produces：記録として、次の 4 点。
  - プラグインの hook から、PATH 上の `cc-ran` を呼べるかどうか。
  - Hook の入力 JSON の実際のキー（値は記録しない）。
  - SessionStart のときに切り離して起動した子プロセスが、Claude Code を終了した後も生き残るかどうか。
  - `CREATE_BREAKAWAY_FROM_JOB` が必要かどうか。
- Consumes：Task 5 のプラグイン

- [ ] **Step 1 [Claude]:** spike の `hookprobe` を書く。バイナリ名は `cc-ran`。
  - `hook` サブコマンド：stdin の JSON の**キー名だけ**と `hook_event_name` を、スクラッチパッドのログファイルに追記し、exit 0 で終わる。stdout には何も出さない。
  - SessionStart のときは、`hookprobe child` を切り離して起動する。
    - Windows：`DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW`
    - 環境変数 `PROBE_BREAKAWAY=1` があれば、`CREATE_BREAKAWAY_FROM_JOB` も付ける。
  - `child` サブコマンド：60 秒のあいだ、1 秒ごとにログに heartbeat を書く。
  - 親プロセスが Job Object に入っているかどうか（`IsProcessInJob`）と、Job が breakaway を許しているかどうかもログに書く。
- [ ] **Step 2 [Claude]:** ビルドし、ユーザーに次の 3 点を案内する。
  - スクラッチパッドの `bin` ディレクトリを、一時的に PATH の先頭に追加する方法。
  - `/plugin marketplace add C:\Users\sabiz\work\cc-ran` と `/plugin install cc-ran@cc-ran` を実行すること。
  - 終わったら元に戻す手順。
- [ ] **Step 3 [User]:** 新しい Claude Code のセッションを起動する。
  - そのセッションで、許可が必要なツールを 1 回実行し、通常の応答を 1 回受ける。
  - その後 `/exit` で終了し、30 秒待つ。
  - 次に `PROBE_BREAKAWAY=1` を設定して、同じことを繰り返す。
- [ ] **Step 4 [Claude]:** ログを確かめる。
  - 期待：
    - 13 イベントのうち、発生したものが記録されている。
    - `/exit` の後も heartbeat が続いているかどうかで、breakaway が必要かどうかを判断できる。
    - Claude Code の画面に Hook のエラーが出ていない。
- [ ] **Step 5 [User]:** プラグインを無効にし、PATH を元に戻す。
- [ ] **Step 6 [Claude]:** macOS の確認を `spikes.yml` に追加して実行する。
  - 動作：`hookprobe hook` を SessionStart の入力で呼び、親プロセスのグループを `kill -- -<pgid>` で終了させる。
  - 期待：`fork` と `setsid` を通った子プロセスが生き残る。
- [ ] **Step 7 [Claude]:** 結果を findings の §12-4 と §12-6 に記録してコミットする。
  - 記録すること：breakaway が必要かどうか、実際の Hook 入力のキーと、Task 4 の fixtures との差分。
  - 差分があれば、fixtures を直してコミットする。

---

### Task 10: mac の `procStart` の形式（spec §12-5）

**Files:** なし。findings に記録するだけ。

- [ ] **Step 1 [Claude]:** Windows で今の `procStart` が何を表しているかを確かめる。
  - `~/.claude/sessions/<pid>.json` の `procStart` を、同じ pid の `Get-Process -Id <pid> | Select StartTime` と比べる。
  - 表示するのは `procStart` と `StartTime` の 2 つの値だけ。
- [ ] **Step 2 [User]:** 手元の Mac で、Claude Code を 1 つ起動したまま、次を実行して結果を貼る。
  - `for f in ~/.claude/sessions/*.json; do jq '{pid, procStart, startedAt, kind, status}' "$f"; done`
    - jq がなければ、ファイルを `cat` して、上記以外の値を伏せる。`*.key` は開かない。
  - `ps -o lstart= -p <pid>`
- [ ] **Step 3 [Claude]:** 比較の方法を決める。
  - `procStart` が OS のプロセス開始時刻から求められるなら、その求め方を platform/macos に書く。
  - 求められないなら、次の方法に倒す。
    - 生存確認：pid が生きている、かつ `startedAt` が OS のプロセス開始時刻と ±2 秒以内。
    - `procStart` は、同じ pid の中で値が変わったかどうかの比較だけに使う。
  - 決めた内容を findings の §12-5 に記録してコミットする。

---

### Task 11: 結果のまとめと、spec の更新

**Files:**
- 変更：`docs/specs/2026-11-05-cc-ran-design.md`（§1.3、§5.3、§12 など、結果によって変わるところ）、`docs/specs/2026-11-05-cc-ran-findings.md`
- 削除：`spikes/`、`.github/workflows/spikes.yml`

- [ ] **Step 1 [Claude]:** findings を読み返し、spec を更新する。
  - 対象になるのは、検証の結果で設計が変わる点。たとえば breakaway のフラグ、`monitor_state` を 1 行テーブルにした変更、`procStart` の比較方法、プラグインに同梱できるかどうか。
  - 変更した点をユーザーに提示し、**承認を得る**。
- [ ] **Step 2 [User]:** spec の変更を承認する。
- [ ] **Step 3 [Claude]:** `spikes/` と `spikes.yml` を削除する。
  - 実行：`cd monitor; zig build test`、`cd ui/avalonia; dotnet test`
  - 期待：両方 PASS。
- [ ] **Step 4 [Claude]:** コミットし（`docs: record foundation findings; remove spikes`）、push して CI が通ることを確かめる。
- [ ] **Step 5 [Claude]:** `docs/plans/2026-11-05-cc-ran-01-monitor.md` と `02-ui.md` を writing-plans skill で書く。
  - I/O を扱う関数のシグネチャは、インストールした Zig 0.17.1 の `lib/std` で確かめる（`zig env` で `lib_dir` を調べて、そこを読む）。
  - Review Focus の 1〜5 を、担当するタスクのテストに入れる。
