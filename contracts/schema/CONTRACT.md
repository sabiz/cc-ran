# cc-ran 公開契約（contract_version 1.0）

UI が依存してよいのは、このファイルで定義する **`v_sessions` と `v_monitor`** だけです。テーブル（`events`、`sessions`、`monitor_state`）は監視側の内部実装なので、UI は直接読みません。

列名と順序の正本は `columns.json` です。

## 共通の規則

- 時刻はすべて UTC の epoch ミリ秒（INTEGER）です。
- DB は `cc-ran.db`（WAL モード）です。
- 読み手は読み取り専用で開き、`PRAGMA data_version` をポーリングして変化を検知します。長いトランザクションは張りません。

## `v_sessions`

1 行 = 1 セッションです。猶予時間を過ぎた `ended` の行は、daemon が削除するのでここには出ません。**表示順は `ORDER BY sort_rank` で決まります。** UI は順序や段階を自分で計算しません。

| 列 | 型 | NULL | 意味 |
|---|---|---|---|
| `session_id` | TEXT | × | Claude Code の session id |
| `origin` | TEXT | × | `local`（将来 `cloud`） |
| `display_name` | TEXT | × | セッション名。なければ `cwd` の末尾のディレクトリ名。daemon が計算します |
| `cwd` | TEXT | ○ | 作業ディレクトリ |
| `kind` | TEXT | × | `interactive` \| `bg` \| `unknown` |
| `attention` | TEXT | × | 下の表の 7 値 |
| `attention_since` | INTEGER | × | 今の状態になった時刻 |
| `context_used_tokens` | INTEGER | ○ | 使用トークン数 |
| `context_window_tokens` | INTEGER | ○ | コンテキストウィンドウのサイズ |
| `context_ratio` | REAL | ○ | 使用数 ÷ ウィンドウ。1.0 を超えることがあります。どちらかが不明、またはウィンドウが 0 なら NULL |
| `context_level` | TEXT | × | `ok` \| `warn` \| `critical` \| `unknown` |
| `window_source` | TEXT | × | `config` \| `builtin` \| `observed` \| `fallback` \| `unknown`。`fallback` のとき UI は「推定」と表示します |
| `model` | TEXT | ○ | 最後に観測したモデル ID |
| `last_activity_at` | INTEGER | × | 最後に活動した時刻 |
| `sort_rank` | INTEGER | × | 表示順 |

### `attention` の値（要対応度の高い順）

| 値 | 意味 |
|---|---|
| `needs_permission` | 承認待ち |
| `needs_input` | 質問や入力を待っている |
| `error` | API エラーでターンが止まった |
| `done` | 作業が完了し、ユーザーの番 |
| `working` | 作業中 |
| `idle` | 起動直後で、まだ指示を受けていない |
| `ended` | 終了した |

## `v_monitor`

常に 1 行です。

| 列 | 型 | NULL | 意味 |
|---|---|---|---|
| `contract_version` | TEXT | × | `major.minor` |
| `daemon_alive` | INTEGER | × | heartbeat が既定の時間（`monitor_state.daemon_stale_ms`、既定 10 秒）以内に更新されていれば 1、そうでなければ 0 |
| `daemon_heartbeat_at` | INTEGER | ○ | 最後の heartbeat。一度も起動していなければ NULL |
| `hooks_seen` | INTEGER | × | Hook のイベントを一度でも受け取っていれば 1（daemon が未処理でも）。0 なら UI は「プラグイン未導入」と案内します |

`daemon_alive` は `unixepoch('subsec')` を使うので、SQLite 3.42 以降が必要です。

## バージョンの規則

契約のバージョンは `major.minor` です。

| 変更 | バージョン |
|---|---|
| 列を末尾に追加する | minor を上げる |
| 列の削除、改名、意味の変更、列挙値の意味の変更 | major を上げる |

- UI は `contract_version` の **major が自分の知っている値と一致するときだけ**表示します。一致しなければ「バージョン不一致」と表示します。
- UI は、知らない列が増えていても動くように、`SELECT *` ではなく列名を指定して読みます。
- 内部スキーマのバージョンは `PRAGMA user_version` で別に管理します（v1 は `1`）。契約のバージョンとは独立しています。
