# cc-ran 基盤の検証結果

plan 00 の検証で分かったことを記録します。spec への反映は Task 11 で行います。

## Hook リファレンスの確認（2026-11-06、`code.claude.com/docs/en/hooks.md`）

plan 01 の reducer に影響する点です。

| 分かったこと | 影響 |
|---|---|
| `SessionStart` は `source` が `startup` / `resume` / `clear` / `compact` / `fork` のときに発火する。`compact` は作業の途中でも発火する | **spec §3.1 の修正が必要**。`compact` で `idle` に戻してはいけない。`events.session_start_source` を追加した（本文ではなく列挙値） |
| `/clear` は `SessionEnd(reason=clear)` の後に、新しい `session_id` で `SessionStart(source=clear)` を出す。このとき `model` は省略されることがある | `/clear` の後のセッションの扱いは Hook だけで判定できる |
| `SubagentStop` は Claude Code の内部エージェント（プロンプト候補、`/btw` など）でも発火する。サブエージェント内の Hook には `agent_id` が付く | `needs_*` を `SubagentStart` / `SubagentStop` やバックグラウンドのサブエージェントの作業イベントで解除すると、本当は承認待ちなのに消えるおそれがある。plan 01 の遷移表で扱う |
| `Notification(permission_prompt)` は約 6 秒遅れて発火し、`PermissionRequest` はすぐに発火する | 承認待ちの検知は `PermissionRequest` が主で、通知は保険 |
| `agent_completed` と `agent_needs_input` は agent view を開いているときだけ発火する | `bg` セッションの完了検知はこれだけに頼らない |
| `Stop` には `background_tasks` と `session_crons` があり、「完了」ではなく「バックグラウンド作業の待ち」の場合がある | v1 では区別しない（`done` として扱う）。将来の候補 |
| `SessionEnd` の既定のタイムアウトは 1.5 秒だが、hook ごとの `timeout` で延びる | `timeout: 5` のままでよい |

## セッションファイルのキー（2026-11-06 の観測）

`asksForConvertedSkills`、`cwd`、`entrypoint`、`kind`、`messagingSocketPath`、`name`、`nameSince`、`nameSource`、`peerFeatures`、`peerProtocol`、`pid`、`pidDomain`、`procStart`（文字列）、`sessionId`、`startedAt`、`status`、`statusUpdatedAt`、`updatedAt`、`version`

## §12-2 Zig 0.17 + SQLite + クロスコンパイル（確認済み）

| 項目 | 結果 |
|---|---|
| SQLite | 3.54.1 の amalgamation を `monitor/vendor/sqlite/` に同梱。`extern` の手書きの宣言で動く |
| クロスコンパイル | Windows から `aarch64-macos` へ通る。出力は Mach-O arm64 で、macOS runner でそのまま実行できる |
| 日本語を含むパス | Windows と macOS の両方で DB を作成できる。`cwd` の日本語も読み書きで一致する |
| 所要時間（起動 → WAL → INSERT → 読み戻し → 終了） | Windows は中央値 20.9ms（何もしない exe は 12.3ms）。macOS は 1 回 約 9ms。目標の 50ms 未満を満たす |
| SQL の埋め込み | `b.path("../contracts/...")` と `addAnonymousImport` で `@embedFile` できる |

plan 01 への注意：

- `SQLITE_TRANSIENT`（-1）は aarch64 の関数ポインタのアラインメントを満たさないので、`Destructor` の型を `align(1)` にしている。x86_64 だけではコンパイルエラーにならないので、CI のクロスコンパイルが必要。
- `synchronous=NORMAL` で測定している。

## §12-3 Native AOT（一部確認済み）

| 項目 | Windows | macOS |
|---|---|---|
| `Microsoft.Data.Sqlite` の AOT 発行 | 成功、警告なし（exe 2.5MB + `e_sqlite3.dll`） | 成功（2.7MB + `libe_sqlite3.dylib`） |
| `Mode=ReadOnly`、WAL の DB、`v_monitor` の読み取り | 動く | 動く |
| 他の接続の書き込みを `PRAGMA data_version` で検知 | できる | できる |
| 読み取り専用の接続での書き込み | `SqliteException` code 8 | 同じ |
| 存在しない DB を開く | `SqliteException` code 14、ファイルは作られない | 同じ |
| Avalonia の TrayIcon と NativeMenu の AOT 発行 | 成功、警告なし（exe 16.7MB + ネイティブ DLL 3 個） | 成功（exe 14.6MB） |
| トレイの目視確認 | 確認待ち | 未確認 |

- 同梱の SQLite は 3.53.3 で、`unixepoch('subsec')` に必要な 3.42 以上を満たす。
- Native AOT の exe には、隣にネイティブライブラリが必要（単一ファイルにはならない）。配布の zip に含める。
- **Windows の AOT には Visual Studio の C++ ツールが必要で、`vswhere.exe` が PATH にないと ILCompiler 10.0.14 の発行が失敗する。** 発行するときは `%ProgramFiles(x86)%\Microsoft Visual Studio\Installer` を PATH に足す。README に書く。

## §12-4 切り離した daemon（macOS は確認済み、Windows は確認待ち）

- macOS：`fork` → `setsid` → stdio を `/dev/null` に切り替え → `execvp` で起動した子プロセスは、親のプロセスグループを `kill -9` で終了させても動き続ける。
- Windows：`bInheritHandles = FALSE` で起動すると Hook はすぐに終わる（Hook の処理は 16ms）。Claude Code の Bash ツールの配下は Job Object の中だが、`BREAKAWAY_OK` と `SILENT_BREAKAWAY_OK` が立っていて、`KILL_ON_JOB_CLOSE` はない。Hook の配下での値は確認待ち。

## §12-5 `procStart`（Windows は確認済み、macOS は確認待ち）

- Windows：`procStart` は OS のプロセス開始時刻の FILETIME（`Process.StartTime` の `ToFileTimeUtc()`）を 10 進の文字列にしたものと、3 セッションすべてで完全に一致した。
- `startedAt` は OS のプロセス開始時刻より 0.7〜6 秒遅れる。**plan 00 の「±2 秒」の代替案は成り立たない。**
