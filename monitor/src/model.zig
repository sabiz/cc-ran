//! 監視側の全体で共有する型。ロジックは置かない。

pub const Attention = enum { needs_permission, needs_input, @"error", done, working, idle, ended };
pub const ContextLevel = enum { ok, warn, critical, unknown };
pub const WindowSource = enum { config, builtin, observed, fallback, unknown };
pub const Kind = enum { interactive, bg, unknown };
pub const FileStatus = enum { busy, idle, unknown };

/// events の 1 行。spec §2.1 の許可リストにある項目だけを持つ。
/// 本文を表す項目（prompt、tool_input など）を足してはいけない。
pub const EventRow = struct {
    received_at: i64,
    session_id: []const u8,
    event: []const u8,
    cwd: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    notification_type: ?[]const u8 = null,
    model: ?[]const u8 = null,
    disable_1m: ?bool = null,
    session_start_source: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
};

pub const StoredEvent = struct {
    seq: i64,
    row: EventRow,
};

pub const AttentionState = struct {
    attention: Attention,
    since: i64,
    /// needs_* や error を起こしたエージェント。null はメインのエージェント。
    agent_id: ?[]const u8 = null,
};
