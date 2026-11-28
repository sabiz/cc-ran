//! Hook の stdin の JSON から、保存してよい項目（spec §2.1）だけを取り出す。I/O を持たない。

const std = @import("std");
const model = @import("model.zig");

const EventRow = model.EventRow;

/// Hook の入力の受け皿。spec §2.1 の許可リストにあるキーだけを書く。
/// ここに書いていないキー（prompt、tool_input、message などの本文）は読まずに捨てる。
/// 本文を表すキーを足してはいけない。
const HookJson = struct {
    session_id: ?[]const u8 = null,
    hook_event_name: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    notification_type: ?[]const u8 = null,
    model: ?[]const u8 = null,
    source: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
};

/// Hook の入力を EventRow にする。
/// - 取り出すのは許可リストの項目だけ。`hook_event_name` は `event`、`source` は `session_start_source` に入れる。
/// - `disable_1m` は引数の値をそのまま入れる（環境変数を読むのは呼び出し側）。
/// - `session_id` か `hook_event_name` がなければ error.MissingField、JSON として読めなければ error.InvalidJson。
pub fn parse(arena: std.mem.Allocator, json: []const u8, received_at: i64, disable_1m: bool) !EventRow {
    const parsed_json = std.json.parseFromSliceLeaky(HookJson, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    return .{
        .session_id = parsed_json.session_id orelse return error.MissingField,
        .event = parsed_json.hook_event_name orelse return error.MissingField,
        .cwd = parsed_json.cwd,
        .transcript_path = parsed_json.transcript_path,
        .tool_name = parsed_json.tool_name,
        .notification_type = parsed_json.notification_type,
        .model = parsed_json.model,
        .session_start_source = parsed_json.source,
        .agent_id = parsed_json.agent_id,
        .received_at = received_at,
        .disable_1m = disable_1m,
    };
}
