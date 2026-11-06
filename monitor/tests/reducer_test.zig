const std = @import("std");
const cc_ran = @import("cc_ran");
const support = @import("support.zig");

const reducer = cc_ran.reducer;
const model = cc_ran.model;
const Attention = model.Attention;
const AttentionState = model.AttentionState;

fn expectState(expected: AttentionState, actual: AttentionState) !void {
    try std.testing.expectEqual(expected.attention, actual.attention);
    try std.testing.expectEqual(expected.since, actual.since);
    if (expected.agent_id) |agent| {
        try std.testing.expectEqualStrings(agent, actual.agent_id orelse return error.TestExpectedEqual);
    } else {
        try std.testing.expectEqual(@as(?[]const u8, null), actual.agent_id);
    }
}

fn attentionFrom(value: std.json.Value) !Attention {
    return std.meta.stringToEnum(Attention, value.string) orelse error.UnknownAttention;
}

/// contracts/fixtures/scenarios/<name>.json を順に適用し、毎ステップの状態を確かめる。
fn runScenario(name: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sub_path = try std.fmt.allocPrint(arena, "fixtures/scenarios/{s}.json", .{name});
    const bytes = try support.readContract(arena, sub_path);
    const root = (try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{})).object;

    const start = root.get("start").?.object;
    var state: AttentionState = .{
        .attention = try attentionFrom(start.get("attention").?),
        .since = start.get("since").?.integer,
    };

    for (root.get("steps").?.array.items, 0..) |step_value, index| {
        const step = step_value.object;
        const at = step.get("at").?.integer;
        const event = if (step.get("input")) |input|
            try support.eventFromFixture(arena, input.string, at)
        else
            model.EventRow{ .received_at = at, .session_id = "s", .event = step.get("event").?.string };

        state = try reducer.apply(state, event);

        const expect = step.get("expect").?.object;
        const agent = expect.get("agent_id").?;
        const expected: AttentionState = .{
            .attention = try attentionFrom(expect.get("attention").?),
            .since = expect.get("since").?.integer,
            .agent_id = if (agent == .null) null else agent.string,
        };
        expectState(expected, state) catch |err| {
            std.debug.print("シナリオ {s} のステップ {d}（at={d}）で不一致です\n", .{ name, index, at });
            return err;
        };
    }
}

const scenario_names = [_][]const u8{
    "basic-turn",
    "permission-approved",
    "permission-denied-then-stop",
    "permission-notification-after-request",
    "permission-notification-alone",
    "parallel-subagent-keeps-permission",
    "main-permission-ignores-subagent",
    "subagent-stop-clears-own-permission",
    "main-stop-clears-subagent-permission",
    "second-agent-permission-keeps-first",
    "permission-overrides-input",
    "done-survives-internal-agent",
    "done-survives-background-work",
    "done-interrupted-by-permission",
    "done-cleared-by-prompt",
    "agent-completed-is-done",
    "idle-not-woken-by-subagent-stop",
    "idle-woken-by-work",
    "compact-keeps-working",
    "error-then-prompt",
    "error-cleared-by-main-work",
    "error-ignores-subagent",
    "input-then-stop",
    "ended-is-final-until-restart",
    "session-start-resets-attention",
    "unknown-ignored",
};

test "scenario: basic-turn" {
    try runScenario("basic-turn");
}
test "scenario: permission-approved" {
    try runScenario("permission-approved");
}
test "scenario: permission-denied-then-stop" {
    try runScenario("permission-denied-then-stop");
}
test "scenario: permission-notification-after-request" {
    try runScenario("permission-notification-after-request");
}
test "scenario: permission-notification-alone" {
    try runScenario("permission-notification-alone");
}
test "scenario: parallel-subagent-keeps-permission" {
    try runScenario("parallel-subagent-keeps-permission");
}
test "scenario: main-permission-ignores-subagent" {
    try runScenario("main-permission-ignores-subagent");
}
test "scenario: subagent-stop-clears-own-permission" {
    try runScenario("subagent-stop-clears-own-permission");
}
test "scenario: main-stop-clears-subagent-permission" {
    try runScenario("main-stop-clears-subagent-permission");
}
test "scenario: second-agent-permission-keeps-first" {
    try runScenario("second-agent-permission-keeps-first");
}
test "scenario: permission-overrides-input" {
    try runScenario("permission-overrides-input");
}
test "scenario: done-survives-internal-agent" {
    try runScenario("done-survives-internal-agent");
}
test "scenario: done-survives-background-work" {
    try runScenario("done-survives-background-work");
}
test "scenario: done-interrupted-by-permission" {
    try runScenario("done-interrupted-by-permission");
}
test "scenario: done-cleared-by-prompt" {
    try runScenario("done-cleared-by-prompt");
}
test "scenario: agent-completed-is-done" {
    try runScenario("agent-completed-is-done");
}
test "scenario: idle-not-woken-by-subagent-stop" {
    try runScenario("idle-not-woken-by-subagent-stop");
}
test "scenario: idle-woken-by-work" {
    try runScenario("idle-woken-by-work");
}
test "scenario: compact-keeps-working" {
    try runScenario("compact-keeps-working");
}
test "scenario: error-then-prompt" {
    try runScenario("error-then-prompt");
}
test "scenario: error-cleared-by-main-work" {
    try runScenario("error-cleared-by-main-work");
}
test "scenario: error-ignores-subagent" {
    try runScenario("error-ignores-subagent");
}
test "scenario: input-then-stop" {
    try runScenario("input-then-stop");
}
test "scenario: ended-is-final-until-restart" {
    try runScenario("ended-is-final-until-restart");
}
test "scenario: session-start-resets-attention" {
    try runScenario("session-start-resets-attention");
}
test "scenario: unknown-ignored" {
    try runScenario("unknown-ignored");
}

test "every scenario file is exercised" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const names = try support.listContractFiles(arena_state.allocator(), "fixtures/scenarios", ".json");

    try std.testing.expectEqual(scenario_names.len, names.len);
    for (names) |file_name| {
        const stem = file_name[0 .. file_name.len - ".json".len];
        var found = false;
        for (scenario_names) |known| found = found or std.mem.eql(u8, known, stem);
        if (!found) std.debug.print("テストに登録されていないシナリオです：{s}\n", .{stem});
        try std.testing.expect(found);
    }
}

test "initial is idle with no agent" {
    try expectState(.{ .attention = .idle, .since = 7 }, try reducer.initial(7));
}

test "reconcile: an interrupted turn becomes idle" {
    const state: AttentionState = .{ .attention = .working, .since = 1000 };
    try expectState(.{ .attention = .idle, .since = 2000 }, try reducer.reconcile(state, .idle, 2000, 5000));
}

test "reconcile: exactly three seconds is enough" {
    const state: AttentionState = .{ .attention = .working, .since = 1000 };
    try expectState(.{ .attention = .idle, .since = 2000 }, try reducer.reconcile(state, .idle, 2000, 5000));
    try expectState(state, try reducer.reconcile(state, .idle, 2000, 4999));
}

test "reconcile: a status older than the turn is ignored" {
    const state: AttentionState = .{ .attention = .working, .since = 1000 };
    try expectState(state, try reducer.reconcile(state, .idle, 1000, 9000));
    try expectState(state, try reducer.reconcile(state, .idle, 999, 9000));
}

test "reconcile: busy, unknown and missing status change nothing" {
    const state: AttentionState = .{ .attention = .working, .since = 1000 };
    try expectState(state, try reducer.reconcile(state, .busy, 2000, 9000));
    try expectState(state, try reducer.reconcile(state, .unknown, 2000, 9000));
    try expectState(state, try reducer.reconcile(state, .idle, null, 9000));
}

test "reconcile: only working is corrected" {
    for ([_]Attention{ .needs_permission, .needs_input, .@"error", .done, .idle, .ended }) |attention| {
        const state: AttentionState = .{ .attention = attention, .since = 1000 };
        try expectState(state, try reducer.reconcile(state, .idle, 2000, 9000));
    }
}

comptime {
    std.testing.refAllDecls(reducer);
}
