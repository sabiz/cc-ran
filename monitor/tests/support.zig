//! テストの共通処理。

const std = @import("std");
const test_options = @import("test_options");
const cc_ran = @import("cc_ran");

const max_fixture_bytes = 64 * 1024 * 1024;

/// contracts/ の下のファイルを読む。呼び出し側が解放する。
pub fn readContract(gpa: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    const path = try std.fs.path.join(gpa, &.{ test_options.contracts_dir, sub_path });
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(max_fixture_bytes));
}

/// contracts/ の下のディレクトリにある、指定の拡張子のファイル名を返す。
pub fn listContractFiles(arena: std.mem.Allocator, sub_path: []const u8, extension: []const u8) ![]const []const u8 {
    const io = std.testing.io;
    const path = try std.fs.path.join(arena, &.{ test_options.contracts_dir, sub_path });
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, extension)) {
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
    }
    return names.items;
}

/// hook-inputs/<name>.json から EventRow を作る。hook_input.parse のテストと独立させるため、ここで直接読む。
pub fn eventFromFixture(arena: std.mem.Allocator, name: []const u8, received_at: i64) !cc_ran.model.EventRow {
    const sub_path = try std.fmt.allocPrint(arena, "fixtures/hook-inputs/{s}.json", .{name});
    const bytes = try readContract(arena, sub_path);
    const root = (try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{})).object;

    const text = struct {
        fn get(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
            const value = object.get(key) orelse return null;
            return if (value == .string) value.string else null;
        }
    }.get;

    return .{
        .received_at = received_at,
        .session_id = text(root, "session_id").?,
        .event = text(root, "hook_event_name").?,
        .cwd = text(root, "cwd"),
        .transcript_path = text(root, "transcript_path"),
        .tool_name = text(root, "tool_name"),
        .notification_type = text(root, "notification_type"),
        .model = text(root, "model"),
        .session_start_source = text(root, "source"),
        .agent_id = text(root, "agent_id"),
    };
}
