const std = @import("std");
const cc_ran = @import("cc_ran");
const support = @import("support.zig");

const hook_input = cc_ran.hook_input;
const EventRow = cc_ran.model.EventRow;

const session_id = "00000000-0000-4000-8000-000000000001";
const cwd = "/home/demo/project";
const transcript_path = "/home/demo/.claude/projects/-home-demo-project/00000000-0000-4000-8000-000000000001.jsonl";
const sentinel = "CCRAN_SECRET_SENTINEL_";
const received_at: i64 = 1_762_300_000_123;

/// contracts/fixtures/README.md の表。書いていない項目は null。
const Case = struct {
    fixture: []const u8,
    event: []const u8,
    tool_name: ?[]const u8 = null,
    notification_type: ?[]const u8 = null,
    model: ?[]const u8 = null,
    source: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
};

const cases = [_]Case{
    .{ .fixture = "SessionStart.startup", .event = "SessionStart", .model = "claude-opus-5-5", .source = "startup" },
    .{ .fixture = "SessionStart.resume", .event = "SessionStart", .model = "claude-opus-5-5", .source = "resume" },
    .{ .fixture = "SessionStart.clear", .event = "SessionStart", .source = "clear" },
    .{ .fixture = "SessionStart.compact", .event = "SessionStart", .model = "claude-opus-5-5", .source = "compact" },
    .{ .fixture = "SessionStart.fork", .event = "SessionStart", .model = "claude-opus-5-5", .source = "fork" },
    .{ .fixture = "SessionEnd", .event = "SessionEnd" },
    .{ .fixture = "UserPromptSubmit", .event = "UserPromptSubmit" },
    .{ .fixture = "PreToolUse", .event = "PreToolUse", .tool_name = "Bash" },
    .{ .fixture = "PreToolUse.subagent", .event = "PreToolUse", .tool_name = "Read", .agent_id = "agent-1" },
    .{ .fixture = "PostToolUse", .event = "PostToolUse", .tool_name = "Write" },
    .{ .fixture = "PostToolUse.subagent", .event = "PostToolUse", .tool_name = "Write", .agent_id = "agent-1" },
    .{ .fixture = "PostToolUseFailure", .event = "PostToolUseFailure", .tool_name = "Bash" },
    .{ .fixture = "PermissionRequest", .event = "PermissionRequest", .tool_name = "Bash" },
    .{ .fixture = "PermissionRequest.subagent", .event = "PermissionRequest", .tool_name = "Bash", .agent_id = "agent-1" },
    .{ .fixture = "SubagentStart", .event = "SubagentStart", .agent_id = "agent-1" },
    .{ .fixture = "SubagentStop", .event = "SubagentStop", .agent_id = "agent-1" },
    .{ .fixture = "SubagentStop.internal", .event = "SubagentStop", .agent_id = "agent-internal" },
    .{ .fixture = "PreCompact", .event = "PreCompact" },
    .{ .fixture = "Stop", .event = "Stop" },
    .{ .fixture = "StopFailure", .event = "StopFailure" },
    .{ .fixture = "Notification.agent_completed", .event = "Notification", .notification_type = "agent_completed" },
    .{ .fixture = "Notification.agent_needs_input", .event = "Notification", .notification_type = "agent_needs_input" },
    .{ .fixture = "Notification.auth_success", .event = "Notification", .notification_type = "auth_success" },
    .{ .fixture = "Notification.elicitation_dialog", .event = "Notification", .notification_type = "elicitation_dialog" },
    .{ .fixture = "Notification.elicitation_url_dialog", .event = "Notification", .notification_type = "elicitation_url_dialog" },
    .{ .fixture = "Notification.idle_prompt", .event = "Notification", .notification_type = "idle_prompt" },
    .{ .fixture = "Notification.permission_prompt", .event = "Notification", .notification_type = "permission_prompt" },
};

fn readFixture(arena: std.mem.Allocator, name: []const u8) ![]u8 {
    return support.readContract(arena, try std.fmt.allocPrint(arena, "fixtures/hook-inputs/{s}.json", .{name}));
}

fn parseFixture(arena: std.mem.Allocator, name: []const u8, disable_1m: bool) !EventRow {
    return hook_input.parse(arena, try readFixture(arena, name), received_at, disable_1m);
}

// ---------------------------------------------------------------------------
// fixtures の表
// ---------------------------------------------------------------------------

test "hook_input.parse: the table covers every hook-inputs fixture" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const names = try support.listContractFiles(arena_state.allocator(), "fixtures/hook-inputs", ".json");
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

test "hook_input.parse: every fixture gives the values in the README table" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (cases) |case| {
        const expected: EventRow = .{
            .received_at = received_at,
            .session_id = session_id,
            .event = case.event,
            .cwd = cwd,
            .transcript_path = transcript_path,
            .tool_name = case.tool_name,
            .notification_type = case.notification_type,
            .model = case.model,
            .disable_1m = false,
            .session_start_source = case.source,
            .agent_id = case.agent_id,
        };
        const actual = try parseFixture(arena, case.fixture, false);
        std.testing.expectEqualDeep(expected, actual) catch |err| {
            std.debug.print("fixture {s} の結果が表と違います\n", .{case.fixture});
            return err;
        };
    }
}

test "hook_input.parse: received_at and disable_1m come from the arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const json = try readFixture(arena, "PreToolUse");

    const enabled = try hook_input.parse(arena, json, 42, true);
    try std.testing.expectEqual(@as(i64, 42), enabled.received_at);
    try std.testing.expectEqual(@as(?bool, true), enabled.disable_1m);

    const disabled = try hook_input.parse(arena, json, 7, false);
    try std.testing.expectEqual(@as(i64, 7), disabled.received_at);
    try std.testing.expectEqual(@as(?bool, false), disabled.disable_1m);
}

// ---------------------------------------------------------------------------
// プライバシー（spec §2.1）
// ---------------------------------------------------------------------------

test "hook_input.parse: no field of any fixture keeps a sentinel string" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (cases) |case| {
        const row = try parseFixture(arena, case.fixture, false);
        inline for (comptime std.meta.fieldNames(EventRow)) |field_name| {
            const value = @field(row, field_name);
            const text: ?[]const u8 = switch (@TypeOf(value)) {
                []const u8 => value,
                ?[]const u8 => value,
                else => null,
            };
            if (text) |t| {
                if (std.mem.indexOf(u8, t, sentinel) != null) {
                    std.debug.print("fixture {s} の {s} に本文が入っています\n", .{ case.fixture, field_name });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

test "hook_input.parse: EventRow has exactly the allowlisted fields" {
    // 本文を表す項目を EventRow に足すと、このテストが失敗する（ガードのテスト。最初から通る）。
    const allowed = [_][]const u8{
        "received_at", "session_id",        "event", "cwd",        "transcript_path",
        "tool_name",   "notification_type", "model", "disable_1m", "session_start_source",
        "agent_id",
    };
    const actual = comptime std.meta.fieldNames(EventRow);
    try std.testing.expectEqual(allowed.len, actual.len);
    for (actual) |field_name| {
        for (allowed) |name| {
            if (std.mem.eql(u8, name, field_name)) break;
        } else {
            std.debug.print("許可リストにない項目です: {s}\n", .{field_name});
            return error.TestUnexpectedResult;
        }
    }
}

// ---------------------------------------------------------------------------
// エラー
// ---------------------------------------------------------------------------

test "hook_input.parse: a missing session_id is MissingField" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.MissingField, hook_input.parse(arena_state.allocator(), "{\"hook_event_name\": \"Stop\", \"cwd\": \"/x\"}", 1, false));
}

test "hook_input.parse: a missing hook_event_name is MissingField" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(error.MissingField, hook_input.parse(arena_state.allocator(), "{\"session_id\": \"s\", \"cwd\": \"/x\"}", 1, false));
}

test "hook_input.parse: input that is not JSON is InvalidJson" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const inputs = [_][]const u8{
        "",
        "{",
        "not json",
        "{\"session_id\": \"s\", \"hook_event_name\": \"Sto",
    };
    for (inputs) |json| {
        std.testing.expectError(error.InvalidJson, hook_input.parse(arena, json, 1, false)) catch |err| {
            std.debug.print("入力 \"{s}\" が InvalidJson になりませんでした\n", .{json});
            return err;
        };
    }
}

comptime {
    std.testing.refAllDecls(hook_input);
}
