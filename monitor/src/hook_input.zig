//! Hook の stdin の JSON から、保存してよい項目（spec §2.1）だけを取り出す。I/O を持たない。

const std = @import("std");
const model = @import("model.zig");

const EventRow = model.EventRow;

/// Hook の入力を EventRow にする。
/// - 取り出すのは許可リストの項目だけ。`hook_event_name` は `event`、`source` は `session_start_source` に入れる。
/// - `disable_1m` は引数の値をそのまま入れる（環境変数を読むのは呼び出し側）。
/// - `session_id` か `hook_event_name` がなければ error.MissingField、JSON として読めなければ error.InvalidJson。
pub fn parse(arena: std.mem.Allocator, json: []const u8, received_at: i64, disable_1m: bool) !EventRow {
    _ = arena;
    _ = json;
    _ = received_at;
    _ = disable_1m;
    return error.NotImplemented;
}
