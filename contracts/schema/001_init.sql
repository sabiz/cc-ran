-- cc-ran スキーマ v1（contract_version 1.0）
-- このファイルは何度実行しても同じ結果になる。
-- WAL への切り替えは、トランザクションの外で実行する必要があるため、ここでは行わず、監視側のコードが行う。
-- 時刻はすべて UTC の epoch ミリ秒。

-- 追記専用のイベント。列は spec §2.1 の許可リストにあるものだけ。本文を入れる列は作らない。
-- event には CHECK を付けない（将来イベントが増えても、hook の INSERT が失敗しないようにするため）。
CREATE TABLE IF NOT EXISTS events (
    seq               INTEGER PRIMARY KEY AUTOINCREMENT,
    received_at       INTEGER NOT NULL,
    origin            TEXT    NOT NULL CHECK (origin IN ('local', 'cloud')),
    source            TEXT    NOT NULL,
    session_id        TEXT    NOT NULL,
    event             TEXT    NOT NULL,
    cwd               TEXT,
    transcript_path   TEXT,
    tool_name         TEXT,
    notification_type TEXT,
    model             TEXT,
    disable_1m        INTEGER CHECK (disable_1m IN (0, 1))
) STRICT;

-- 集約したセッションの状態。書くのは daemon だけ。
-- 猶予期間を過ぎた ended の行は daemon が DELETE するので、VIEW には時刻による絞り込みを入れない。
CREATE TABLE IF NOT EXISTS sessions (
    session_id            TEXT    PRIMARY KEY,
    origin                TEXT    NOT NULL DEFAULT 'local' CHECK (origin IN ('local', 'cloud')),
    pid                   INTEGER,
    proc_start            TEXT,
    name                  TEXT,
    display_name          TEXT    NOT NULL,
    cwd                   TEXT,
    kind                  TEXT    NOT NULL DEFAULT 'unknown' CHECK (kind IN ('interactive', 'bg', 'unknown')),
    transcript_path       TEXT,
    model                 TEXT,
    disable_1m            INTEGER NOT NULL DEFAULT 0 CHECK (disable_1m IN (0, 1)),
    attention             TEXT    NOT NULL CHECK (attention IN
                              ('needs_permission', 'needs_input', 'error', 'done', 'working', 'idle', 'ended')),
    attention_since       INTEGER NOT NULL,
    last_event_seq        INTEGER,
    last_activity_at      INTEGER NOT NULL,
    ended_at              INTEGER,
    context_used_tokens   INTEGER,
    context_window_tokens INTEGER,
    context_level         TEXT    NOT NULL DEFAULT 'unknown' CHECK (context_level IN ('ok', 'warn', 'critical', 'unknown')),
    window_source         TEXT    NOT NULL DEFAULT 'unknown' CHECK (window_source IN ('config', 'builtin', 'observed', 'fallback', 'unknown')),
    sort_rank             INTEGER NOT NULL
) STRICT;

-- 監視側そのものの状態。常に 1 行だけ。書くのは daemon だけ。
CREATE TABLE IF NOT EXISTS monitor_state (
    id                  INTEGER PRIMARY KEY CHECK (id = 1),
    contract_version    TEXT    NOT NULL,
    daemon_pid          INTEGER,
    daemon_proc_start   TEXT,
    daemon_heartbeat_at INTEGER,
    daemon_stale_ms     INTEGER NOT NULL DEFAULT 10000,
    last_processed_seq  INTEGER NOT NULL DEFAULT 0,
    hooks_seen          INTEGER NOT NULL DEFAULT 0 CHECK (hooks_seen IN (0, 1)),
    last_hook_at        INTEGER
) STRICT;

INSERT OR IGNORE INTO monitor_state (id, contract_version) VALUES (1, '1.0');

-- 公開 VIEW。UI が読んでよいのはここから下だけ。列の定義の正本は columns.json。
CREATE VIEW IF NOT EXISTS v_sessions AS
SELECT
    session_id,
    origin,
    display_name,
    cwd,
    kind,
    attention,
    attention_since,
    context_used_tokens,
    context_window_tokens,
    CASE
        WHEN context_used_tokens IS NOT NULL AND context_window_tokens > 0
        THEN CAST(context_used_tokens AS REAL) / context_window_tokens
    END AS context_ratio,
    context_level,
    window_source,
    model,
    last_activity_at,
    sort_rank
FROM sessions;

CREATE VIEW IF NOT EXISTS v_monitor AS
SELECT
    contract_version,
    CASE
        WHEN daemon_heartbeat_at IS NOT NULL
             AND CAST(unixepoch('subsec') * 1000 AS INTEGER) - daemon_heartbeat_at <= daemon_stale_ms
        THEN 1
        ELSE 0
    END AS daemon_alive,
    daemon_heartbeat_at,
    hooks_seen
FROM monitor_state;

PRAGMA user_version = 1;
