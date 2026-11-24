const std = @import("std");
const cc_ran = @import("cc_ran");
const support = @import("support.zig");

const session_file = cc_ran.session_file;
const SessionFile = session_file.SessionFile;

const session_id = "00000000-0000-4000-8000-000000000001";

/// contracts/fixtures/README.md の共通の値。kind、status、name だけを変える。
fn common(kind: cc_ran.model.Kind, status: cc_ran.model.FileStatus, name: ?[]const u8) SessionFile {
    return .{
        .session_id = session_id,
        .pid = 4242,
        .proc_start = "opaque-proc-start-1",
        .cwd = "/home/demo/project",
        .name = name,
        .kind = kind,
        .status = status,
        .status_updated_at = 1_762_300_001_000,
    };
}

const Case = struct {
    fixture: []const u8,
    /// null は「読み飛ばす」（parse が null を返す）
    expected: ?SessionFile,
};

const cases = [_]Case{
    .{ .fixture = "interactive-busy", .expected = common(.interactive, .busy, "demo-session") },
    .{ .fixture = "interactive-idle", .expected = common(.interactive, .idle, "demo-session") },
    .{ .fixture = "bg-idle", .expected = common(.bg, .idle, "demo-session") },
    .{ .fixture = "no-name", .expected = common(.interactive, .busy, null) },
    .{ .fixture = "unknown-fields", .expected = common(.unknown, .unknown, "demo-session") },
    .{ .fixture = "missing-fields", .expected = .{
        .session_id = session_id,
        .pid = 4242,
        .proc_start = null,
        .cwd = null,
        .name = null,
        .kind = .unknown,
        .status = .unknown,
        .status_updated_at = null,
    } },
    .{ .fixture = "broken", .expected = null },
};

// ---------------------------------------------------------------------------
// parse
// ---------------------------------------------------------------------------

test "session_file.parse: the table covers every session-files fixture" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const names = try support.listContractFiles(arena_state.allocator(), "fixtures/session-files", ".json");
    try std.testing.expectEqual(cases.len, names.len);
    for (names) |file_name| {
        const stem = file_name[0 .. file_name.len - ".json".len];
        for (cases) |case| {
            if (std.mem.eql(u8, case.fixture, stem)) break;
        } else {
            std.debug.print("表にない fixture です: {s}\n", .{file_name});
            return error.TestUnexpectedResult;
        }
    }
}

test "session_file.parse: every fixture gives the values in the README table" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (cases) |case| {
        const json = try support.readContract(arena, try std.fmt.allocPrint(arena, "fixtures/session-files/{s}.json", .{case.fixture}));
        const actual = try session_file.parse(arena, json);
        std.testing.expectEqualDeep(case.expected, actual) catch |err| {
            std.debug.print("fixture {s} の結果が表と違います\n", .{case.fixture});
            return err;
        };
    }
}

test "session_file.parse: empty input is skipped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqual(@as(?SessionFile, null), try session_file.parse(arena_state.allocator(), ""));
}

test "session_file.parse: a file without sessionId or pid is skipped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqual(@as(?SessionFile, null), try session_file.parse(arena, "{\"pid\": 4242, \"cwd\": \"/x\"}"));
    try std.testing.expectEqual(@as(?SessionFile, null), try session_file.parse(arena, "{\"sessionId\": \"s\", \"cwd\": \"/x\"}"));
}

// ---------------------------------------------------------------------------
// displayName
// ---------------------------------------------------------------------------

test "session_file.displayName: the name comes first" {
    try std.testing.expectEqualStrings("demo-session", try session_file.displayName("demo-session", "/home/demo/project", session_id));
}

test "session_file.displayName: without a name, the last directory of cwd" {
    try std.testing.expectEqualStrings("project", try session_file.displayName(null, "/home/demo/project", session_id));
    try std.testing.expectEqualStrings("project", try session_file.displayName(null, "/home/demo/project/", session_id));
    try std.testing.expectEqualStrings("プロジェクト", try session_file.displayName(null, "C:\\Users\\x\\プロジェクト", session_id));
    try std.testing.expectEqualStrings("プロジェクト", try session_file.displayName(null, "C:\\Users\\x\\プロジェクト\\", session_id));
}

test "session_file.displayName: without a name or cwd, the first 8 characters of the session id" {
    try std.testing.expectEqualStrings("00000000", try session_file.displayName(null, null, session_id));
    try std.testing.expectEqualStrings("abcdef12", try session_file.displayName(null, null, "abcdef12-3456"));
    try std.testing.expectEqualStrings("short", try session_file.displayName(null, null, "short"));
}

// ---------------------------------------------------------------------------
// scanDir
// ---------------------------------------------------------------------------

/// tmp の中の sub_path を、テストの作業ディレクトリからの相対パスにする。
fn tmpPath(arena: std.mem.Allocator, tmp: *const std.testing.TmpDir, sub_path: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path, sub_path });
}

/// 見つかった session_id を昇順で返す（scanDir は順序を決めない）。
fn sortedIds(arena: std.mem.Allocator, files: []const SessionFile) ![]const []const u8 {
    const ids = try arena.alloc([]const u8, files.len);
    for (files, ids) |file, *id| id.* = file.session_id;
    std.mem.sort([]const u8, ids, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return ids;
}

fn writeSessionsDir(tmp: *const std.testing.TmpDir, dir_name: []const u8) !void {
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, dir_name);
    const files = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "100.json", .data = "{\"pid\": 100, \"sessionId\": \"s-a\"}" },
        .{ .name = "200.json", .data = "{\"pid\": 200, \"sessionId\": \"s-b\", \"kind\": \"bg\"}" },
        .{ .name = "300.json", .data = "{\"pid\": 300, \"sessionId\": \"s-bro" },
        // 中身は正しい JSON でも、.key は開かない。.txt も読まない。
        .{ .name = "abc.key", .data = "{\"pid\": 400, \"sessionId\": \"s-key\"}" },
        .{ .name = "notes.txt", .data = "{\"pid\": 500, \"sessionId\": \"s-txt\"}" },
    };
    for (files) |file| {
        const sub_path = try std.fs.path.join(std.testing.allocator, &.{ dir_name, file.name });
        defer std.testing.allocator.free(sub_path);
        try tmp.dir.writeFile(io, .{ .sub_path = sub_path, .data = file.data });
    }
    // 名前が .json のディレクトリも飛ばす。
    const dir_like_file = try std.fs.path.join(std.testing.allocator, &.{ dir_name, "600.json" });
    defer std.testing.allocator.free(dir_like_file);
    try tmp.dir.createDirPath(io, dir_like_file);
}

test "session_file.scanDir: reads only the readable .json files" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSessionsDir(&tmp, "sessions");

    const files = try session_file.scanDir(std.testing.io, arena, try tmpPath(arena, &tmp, "sessions"));
    const ids = try sortedIds(arena, files);
    try std.testing.expectEqual(@as(usize, 2), ids.len);
    try std.testing.expectEqualStrings("s-a", ids[0]);
    try std.testing.expectEqualStrings("s-b", ids[1]);
}

test "session_file.scanDir: works under a non-ASCII path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSessionsDir(&tmp, "ユーザー/セッション");

    const files = try session_file.scanDir(std.testing.io, arena, try tmpPath(arena, &tmp, "ユーザー/セッション"));
    try std.testing.expectEqual(@as(usize, 2), files.len);
}

test "session_file.scanDir: a missing directory gives an empty list" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const files = try session_file.scanDir(std.testing.io, arena, try tmpPath(arena, &tmp, "no-such-dir"));
    try std.testing.expectEqual(@as(usize, 0), files.len);
}

comptime {
    std.testing.refAllDecls(session_file);
}
