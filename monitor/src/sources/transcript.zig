//! transcript（.jsonl）の末尾から、最後の assistant 行のモデルと使用量を読む（spec §4.1）。
//! 読む項目は type、isSidechain、message.model、message.usage だけ。本文は読まない。

const std = @import("std");

pub const Usage = struct {
    model: []const u8,
    /// input_tokens + cache_creation_input_tokens + cache_read_input_tokens（output_tokens は足さない）
    used: u64,
};

/// 末尾の読み取り範囲の初期値と上限（spec §9）
pub const initial_tail_bytes: usize = 256 * 1024;
pub const max_tail_bytes: usize = 4 * 1024 * 1024;

/// tail の中で条件に合う最後の assistant 行を探す。なければ null。
/// - 対象外：`isSidechain` が true の行、`message.model` が `<synthetic>` の行。
/// - JSON として読めない行（途中から始まる先頭行、途中で切れた行）は無視する。
pub fn extractUsage(arena: std.mem.Allocator, tail: []const u8) !?Usage {
    _ = arena;
    _ = tail;
    return error.NotImplemented;
}

/// path の末尾を initial_tail_bytes から倍々に広げて読み、max_tail_bytes まで探す。
/// ファイルがなければ null。返した model は gpa で確保したもので、呼び出し側が解放する。
pub fn readUsage(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !?Usage {
    _ = io;
    _ = gpa;
    _ = path;
    return error.NotImplemented;
}
