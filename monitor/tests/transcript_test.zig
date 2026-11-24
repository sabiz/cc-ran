const std = @import("std");
const cc_ran = @import("cc_ran");
const support = @import("support.zig");

const transcript = cc_ran.transcript;
const Usage = transcript.Usage;

const sentinel = "CCRAN_SECRET_SENTINEL_";

/// contracts/fixtures/README.md の表。null は「assistant 行がない」。
const Case = struct {
    fixture: []const u8,
    expected: ?Usage,
};

const cases = [_]Case{
    .{ .fixture = "last-assistant", .expected = .{ .model = "claude-opus-5-5", .used = 123_456 } },
    .{ .fixture = "sidechain-last", .expected = .{ .model = "claude-opus-5-5", .used = 50_000 } },
    .{ .fixture = "synthetic-last", .expected = .{ .model = "claude-opus-5-5", .used = 70_000 } },
    .{ .fixture = "dated-model", .expected = .{ .model = "claude-haiku-4-5-20251001", .used = 60_000 } },
    .{ .fixture = "over-window", .expected = .{ .model = "claude-opus-4-6", .used = 500_000 } },
    .{ .fixture = "unknown-model", .expected = .{ .model = "claude-future-9", .used = 40_000 } },
    .{ .fixture = "no-assistant", .expected = null },
    .{ .fixture = "broken-line", .expected = .{ .model = "claude-opus-5-5", .used = 80_000 } },
};

fn readFixture(arena: std.mem.Allocator, name: []const u8) ![]u8 {
    return support.readContract(arena, try std.fmt.allocPrint(arena, "fixtures/transcripts/{s}.jsonl", .{name}));
}

// ---------------------------------------------------------------------------
// extractUsage
// ---------------------------------------------------------------------------

test "transcript.extractUsage: the table covers every transcripts fixture" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const names = try support.listContractFiles(arena_state.allocator(), "fixtures/transcripts", ".jsonl");
    try std.testing.expectEqual(cases.len, names.len);
    for (names) |file_name| {
        const stem = file_name[0 .. file_name.len - ".jsonl".len];
        for (cases) |case| {
            if (std.mem.eql(u8, case.fixture, stem)) break;
        } else {
            std.debug.print("表にない fixture です: {s}\n", .{file_name});
            return error.TestUnexpectedResult;
        }
    }
}

test "transcript.extractUsage: every fixture gives the values in the README table" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (cases) |case| {
        const actual = try transcript.extractUsage(arena, try readFixture(arena, case.fixture));
        std.testing.expectEqualDeep(case.expected, actual) catch |err| {
            std.debug.print("fixture {s} の結果が表と違います\n", .{case.fixture});
            return err;
        };
    }
}

test "transcript.extractUsage: the result never keeps a sentinel string" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (cases) |case| {
        if (try transcript.extractUsage(arena, try readFixture(arena, case.fixture))) |usage| {
            if (std.mem.indexOf(u8, usage.model, sentinel) != null) {
                std.debug.print("fixture {s} の model に本文が入っています\n", .{case.fixture});
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "transcript.extractUsage: a tail cut in the middle of the last line uses the line before it" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = try readFixture(arena, "last-assistant");
    // 最後の行（claude-opus-5-5）を途中で切ると、その前の assistant 行（claude-sonnet-5-5、1+2+3）が最後になる。
    const cut = std.mem.lastIndexOf(u8, bytes, "\"usage\"").?;
    try std.testing.expectEqualDeep(@as(?Usage, .{ .model = "claude-sonnet-5-5", .used = 6 }), try transcript.extractUsage(arena, bytes[0..cut]));
}

test "transcript.extractUsage: a tail that starts in the middle of a line skips that line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bytes = try readFixture(arena, "last-assistant");

    // 2 行目（sonnet）の途中から始めても、最後の行（opus）は読める。
    const in_second_line = std.mem.indexOf(u8, bytes, "claude-sonnet-5-5").?;
    try std.testing.expectEqualDeep(@as(?Usage, .{ .model = "claude-opus-5-5", .used = 123_456 }), try transcript.extractUsage(arena, bytes[in_second_line..]));

    // 最後の行の途中から始めると、完全な assistant 行はない。
    const in_last_line = std.mem.indexOf(u8, bytes, "claude-opus-5-5").?;
    try std.testing.expectEqual(@as(?Usage, null), try transcript.extractUsage(arena, bytes[in_last_line..]));
}

test "transcript.extractUsage: only assistant lines count" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // 最後の行は model と usage を持つが、type が assistant ではない。
    const tail =
        \\{"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-5-5","usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3}}}
        \\{"type":"system","isSidechain":false,"message":{"model":"claude-other","usage":{"input_tokens":9,"cache_creation_input_tokens":9,"cache_read_input_tokens":9}}}
    ;
    try std.testing.expectEqualDeep(@as(?Usage, .{ .model = "claude-opus-5-5", .used = 6 }), try transcript.extractUsage(arena_state.allocator(), tail));
}

test "transcript.extractUsage: a line without isSidechain is not a sidechain" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    // 除外するのは isSidechain が true の行だけ。項目がない行は対象にする。
    const tail =
        \\{"type":"assistant","message":{"model":"claude-opus-5-5","usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3}}}
    ;
    try std.testing.expectEqualDeep(@as(?Usage, .{ .model = "claude-opus-5-5", .used = 6 }), try transcript.extractUsage(arena_state.allocator(), tail));
}

test "transcript.extractUsage: an empty tail gives null" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqual(@as(?Usage, null), try transcript.extractUsage(arena_state.allocator(), ""));
}

// ---------------------------------------------------------------------------
// readUsage
// ---------------------------------------------------------------------------

const assistant_line =
    \\{"type":"assistant","isSidechain":false,"message":{"model":"claude-opus-5-5","role":"assistant","content":[{"type":"text","text":"x"}],"usage":{"output_tokens":9,"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":300}}}
++ "\n";
const assistant_used: u64 = 303;

/// tmp の中の sub_path を、テストの作業ディレクトリからの相対パスにする。
fn tmpPath(arena: std.mem.Allocator, tmp: *const std.testing.TmpDir, sub_path: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ ".zig-cache", "tmp", &tmp.sub_path, sub_path });
}

/// assistant 行の後に、本文が content_bytes バイトの user 行を line_count 行書く。
fn writeAssistantThenUsers(tmp: *const std.testing.TmpDir, sub_path: []const u8, line_count: usize, content_bytes: usize) !void {
    const io = std.testing.io;
    var file = try tmp.dir.createFile(io, sub_path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(io, &buffer);
    const writer = &file_writer.interface;
    const content = try std.testing.allocator.alloc(u8, content_bytes);
    defer std.testing.allocator.free(content);
    @memset(content, 'a');
    try writer.writeAll(assistant_line);
    for (0..line_count) |_| {
        try writer.writeAll("{\"type\":\"user\",\"isSidechain\":false,\"message\":{\"role\":\"user\",\"content\":\"");
        try writer.writeAll(content);
        try writer.writeAll("\"}}\n");
    }
    try writer.flush();
}

/// readUsage を呼び、結果の model を gpa に返す（解放漏れは std.testing.allocator が見つける）。
fn readUsageFreed(path: []const u8) !?Usage {
    const gpa = std.testing.allocator;
    const usage = (try transcript.readUsage(std.testing.io, gpa, path)) orelse return null;
    defer gpa.free(usage.model);
    // 解放の前に、比較用の値を作る（model は呼び出し側の文字列と比べるだけなので、ここで判定する）。
    if (!std.mem.eql(u8, usage.model, "claude-opus-5-5")) {
        std.debug.print("model が違います: {s}\n", .{usage.model});
        return error.TestUnexpectedResult;
    }
    return .{ .model = "claude-opus-5-5", .used = usage.used };
}

test "transcript.readUsage: reads a fixture file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "t.jsonl", .data = try readFixture(arena, "last-assistant") });

    try std.testing.expectEqualDeep(@as(?Usage, .{ .model = "claude-opus-5-5", .used = 123_456 }), try readUsageFreed(try tmpPath(arena, &tmp, "t.jsonl")));
}

test "transcript.readUsage: a small file whose only assistant is the first line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // ファイル全体を読めたときは、先頭行も完全な行として扱う。
    try writeAssistantThenUsers(&tmp, "t.jsonl", 1, 10);

    try std.testing.expectEqualDeep(@as(?Usage, .{ .model = "claude-opus-5-5", .used = assistant_used }), try readUsageFreed(try tmpPath(arena, &tmp, "t.jsonl")));
}

test "transcript.readUsage: finds the assistant behind a 1 MiB user line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 256 KiB の初期値では届かず、倍々に広げると届く。
    try writeAssistantThenUsers(&tmp, "t.jsonl", 1, 1024 * 1024);

    try std.testing.expectEqualDeep(@as(?Usage, .{ .model = "claude-opus-5-5", .used = assistant_used }), try readUsageFreed(try tmpPath(arena, &tmp, "t.jsonl")));
}

test "transcript.readUsage: an assistant further than 4 MiB from the end is not found" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // 1 MiB の user 行を 5 行。assistant 行は末尾から 5 MiB 以上離れる。
    try writeAssistantThenUsers(&tmp, "t.jsonl", 5, 1024 * 1024);

    try std.testing.expectEqual(@as(?Usage, null), try readUsageFreed(try tmpPath(arena, &tmp, "t.jsonl")));
}

test "transcript.readUsage: a missing file gives null" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try std.testing.expectEqual(@as(?Usage, null), try readUsageFreed(try tmpPath(arena, &tmp, "missing.jsonl")));
}

test "transcript.readUsage: works under a non-ASCII path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "プロジェクト");
    try writeAssistantThenUsers(&tmp, "プロジェクト/会話.jsonl", 1, 10);

    try std.testing.expectEqualDeep(@as(?Usage, .{ .model = "claude-opus-5-5", .used = assistant_used }), try readUsageFreed(try tmpPath(arena, &tmp, "プロジェクト/会話.jsonl")));
}

comptime {
    std.testing.refAllDecls(transcript);
}
