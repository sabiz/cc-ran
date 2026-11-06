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
