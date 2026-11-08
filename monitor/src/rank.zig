//! 一覧の並び順（spec §3.3）。I/O を持たない純粋な関数だけを置く。

const std = @import("std");
const model = @import("model.zig");

const Attention = model.Attention;
const ContextLevel = model.ContextLevel;

pub const RankInput = struct {
    session_id: []const u8,
    attention: Attention,
    level: ContextLevel,
    last_activity_at: i64,
};

/// out[i] に inputs[i] の表示順（0 始まり）を入れる。out の長さは inputs と同じ。
/// 順序：attention の重さ → コンテキストの段階 → last_activity_at の新しい順 → session_id の昇順。
pub fn assign(gpa: std.mem.Allocator, inputs: []const RankInput, out: []i64) !void {
    _ = gpa;
    _ = inputs;
    _ = out;
    return error.NotImplemented;
}
