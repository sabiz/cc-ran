# fixtures

テスト用の入力データです。**手で管理する唯一の正**で、どちらの側からも自動生成しません。値はすべてダミーです。

ファイル名の規則は次のとおりです。

- `hook-inputs/<Event>[.<variant>].json`
- `session-files/<case>.json`
- `transcripts/<case>.jsonl`

`scenarios/` と `db-seeds/` は、それを使うテストと一緒に plan 01 / 02 で追加します。

## 目印の文字列

本文を表す項目には、目印の文字列 `CCRAN_SECRET_SENTINEL_<n>` を入れてあります。監視側のプライバシーテストは、この文字列が DB と WAL のバイト列に残らないことを確かめます。

| 目印を入れてある項目 | 備考 |
|---|---|
| `prompt`、`tool_input`、`tool_response`、`last_assistant_message`、`message`、`title` | 本文 |
| `error`（PostToolUseFailure のとき）、`error_details`、`custom_instructions`、`session_title` | 本文。StopFailure の `error` は列挙値なので入れない |
| transcript の `message.content` | 本文 |

## `hook-inputs/`：保存してよい項目の期待値

すべての fixture の共通の値は次のとおりです。

| 項目 | 値 |
|---|---|
| `session_id` | `00000000-0000-4000-8000-000000000001` |
| `cwd` | `/home/demo/project` |
| `transcript_path` | `/home/demo/.claude/projects/-home-demo-project/00000000-0000-4000-8000-000000000001.jsonl` |

イベントごとの項目（表にないものは NULL）は次のとおりです。

| fixture | `event` | `tool_name` | `notification_type` | `model` | `session_start_source` |
|---|---|---|---|---|---|
| `SessionStart.startup` | `SessionStart` | | | `claude-opus-5-5` | `startup` |
| `SessionStart.resume` | `SessionStart` | | | `claude-opus-5-5` | `resume` |
| `SessionStart.clear` | `SessionStart` | | | | `clear` |
| `SessionStart.compact` | `SessionStart` | | | `claude-opus-5-5` | `compact` |
| `SessionStart.fork` | `SessionStart` | | | `claude-opus-5-5` | `fork` |
| `SessionEnd` | `SessionEnd` | | | | |
| `UserPromptSubmit` | `UserPromptSubmit` | | | | |
| `PreToolUse` | `PreToolUse` | `Bash` | | | |
| `PreToolUse.subagent` | `PreToolUse` | `Read` | | | |
| `PostToolUse.subagent` | `PostToolUse` | `Write` | | | |
| `PermissionRequest.subagent` | `PermissionRequest` | `Bash` | | | |
| `PostToolUse` | `PostToolUse` | `Write` | | | |
| `PostToolUseFailure` | `PostToolUseFailure` | `Bash` | | | |
| `SubagentStart` | `SubagentStart` | | | | |
| `SubagentStop` | `SubagentStop` | | | | |
| `SubagentStop.internal` | `SubagentStop` | | | | |
| `PreCompact` | `PreCompact` | | | | |
| `PermissionRequest` | `PermissionRequest` | `Bash` | | | |
| `Notification.<type>` | `Notification` | | `<type>` | | |
| `Stop` | `Stop` | | | | |
| `StopFailure` | `StopFailure` | | | | |

## `session-files/`：期待する抽出結果

共通の値は `sessionId = 00000000-0000-4000-8000-000000000001`、`pid = 4242`、`cwd = /home/demo/project`、`procStart = opaque-proc-start-1` です（`missing-fields` と `broken` を除く）。

| fixture | `kind` | `status` | `name` | 備考 |
|---|---|---|---|---|
| `interactive-busy` | `interactive` | `busy` | `demo-session` | |
| `interactive-idle` | `interactive` | `idle` | `demo-session` | |
| `bg-idle` | `bg` | `idle` | `demo-session` | |
| `no-name` | `interactive` | `busy` | なし | `display_name` は `project` になる |
| `unknown-fields` | `unknown` | 不明として扱う | `demo-session` | 知らないキーと、知らない列挙値がある。失敗しないこと |
| `missing-fields` | `unknown` | 不明として扱う | なし | `pid` と `sessionId` だけ。失敗しないこと |
| `broken` | — | — | — | 壊れた JSON（書き込みの途中を想定）。読み飛ばすだけで、失敗しないこと |

## `transcripts/`：期待する抽出結果

| fixture | `model` | 使用量 | 確かめること |
|---|---|---|---|
| `last-assistant` | `claude-opus-5-5` | 123456 | 最後の assistant を使う。`output_tokens` は足さない |
| `sidechain-last` | `claude-opus-5-5` | 50000 | `isSidechain: true` の行を飛ばす |
| `synthetic-last` | `claude-opus-5-5` | 70000 | `<synthetic>` の行を飛ばす |
| `dated-model` | `claude-haiku-4-5-20251001` | 60000 | 照合するときは日付を外して `claude-haiku-4-5`（window 200000、`builtin`） |
| `over-window` | `claude-opus-4-6` | 500000 | 表の 200000 を超えるので window 1000000、`observed` |
| `unknown-model` | `claude-future-9` | 40000 | 表にないので window 200000、`fallback` |
| `no-assistant` | なし | なし | `context_level = unknown`、`window_source = unknown` |
| `broken-line` | `claude-opus-5-5` | 80000 | 末尾の壊れた行を無視する |

## `agent_id`

`agent_id` は、サブエージェントの中で発火した Hook にだけ入ります（表にないものは NULL）。

| fixture | `agent_id` |
|---|---|
| `PreToolUse.subagent`、`PostToolUse.subagent`、`PermissionRequest.subagent`、`SubagentStart`、`SubagentStop` | `agent-1` |
| `SubagentStop.internal` | `agent-internal` |

`SubagentStop.internal` は、Claude Code の内部エージェントのものです。`SubagentStart` なしで、`Stop` の後に届きます（2026-11-06 に観測）。`done` を `working` に戻してはいけません。
