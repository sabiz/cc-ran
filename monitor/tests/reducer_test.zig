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

        state = reducer.apply(state, event);

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

test "apply scenario:basic-turn" {
    try runScenario("basic-turn");
}
test "apply scenario:permission-approved" {
    try runScenario("permission-approved");
}
test "apply scenario:permission-denied-then-stop" {
    try runScenario("permission-denied-then-stop");
}
test "apply scenario:permission-notification-after-request" {
    try runScenario("permission-notification-after-request");
}
test "apply scenario:permission-notification-alone" {
    try runScenario("permission-notification-alone");
}
test "apply scenario:parallel-subagent-keeps-permission" {
    try runScenario("parallel-subagent-keeps-permission");
}
test "apply scenario:main-permission-ignores-subagent" {
    try runScenario("main-permission-ignores-subagent");
}
test "apply scenario:subagent-stop-clears-own-permission" {
    try runScenario("subagent-stop-clears-own-permission");
}
test "apply scenario:main-stop-clears-subagent-permission" {
    try runScenario("main-stop-clears-subagent-permission");
}
test "apply scenario:second-agent-permission-keeps-first" {
    try runScenario("second-agent-permission-keeps-first");
}
test "apply scenario:permission-overrides-input" {
    try runScenario("permission-overrides-input");
}
test "apply scenario:done-survives-internal-agent" {
    try runScenario("done-survives-internal-agent");
}
test "apply scenario:done-survives-background-work" {
    try runScenario("done-survives-background-work");
}
test "apply scenario:done-interrupted-by-permission" {
    try runScenario("done-interrupted-by-permission");
}
test "apply scenario:done-cleared-by-prompt" {
    try runScenario("done-cleared-by-prompt");
}
test "apply scenario:agent-completed-is-done" {
    try runScenario("agent-completed-is-done");
}
test "apply scenario:idle-not-woken-by-subagent-stop" {
    try runScenario("idle-not-woken-by-subagent-stop");
}
test "apply scenario:idle-woken-by-work" {
    try runScenario("idle-woken-by-work");
}
test "apply scenario:compact-keeps-working" {
    try runScenario("compact-keeps-working");
}
test "apply scenario:error-then-prompt" {
    try runScenario("error-then-prompt");
}
test "apply scenario:error-cleared-by-main-work" {
    try runScenario("error-cleared-by-main-work");
}
test "apply scenario:error-ignores-subagent" {
    try runScenario("error-ignores-subagent");
}
test "apply scenario:input-then-stop" {
    try runScenario("input-then-stop");
}
test "apply scenario:ended-is-final-until-restart" {
    try runScenario("ended-is-final-until-restart");
}
test "apply scenario:session-start-resets-attention" {
    try runScenario("session-start-resets-attention");
}
test "apply scenario:unknown-ignored" {
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

// ---------------------------------------------------------------------------
// 状態遷移表（spec §3、plan 01 の Task 2）
//
// シナリオは利用の流れを示す例で、すべての組み合わせは通らない。
// ここでは「開始状態 × イベント」のすべてのセルを、期待値を直接書いて確かめる。
// ---------------------------------------------------------------------------

/// 状態が何も変わらないこと（attention も since も agent_id も）。
const stay: ?Attention = null;

/// 開始状態ごとの移動先。既定値を置かないので、開始状態を書き漏らすとコンパイルエラーになる。
/// 移動先を書いたセルは、since がイベントの時刻になり、agent_id がなくなることを確かめる。
const Moves = struct {
    needs_permission: ?Attention,
    needs_input: ?Attention,
    @"error": ?Attention,
    done: ?Attention,
    working: ?Attention,
    idle: ?Attention,
    ended: ?Attention,
};

const start_time = 1000;
const event_time = 2000;

const agent_1: []const u8 = "agent-1";
const agent_2: []const u8 = "agent-2";

fn named(name: []const u8) model.EventRow {
    return .{ .received_at = event_time, .session_id = "s", .event = name };
}

fn notification(notification_type: ?[]const u8) model.EventRow {
    var event = named("Notification");
    event.notification_type = notification_type;
    return event;
}

fn sessionStart(source: ?[]const u8) model.EventRow {
    var event = named("SessionStart");
    event.session_start_source = source;
    return event;
}

fn by(agent: ?[]const u8, base: model.EventRow) model.EventRow {
    var event = base;
    event.agent_id = agent;
    return event;
}

/// 1 行のすべてのセルを確かめ、不一致をまとめて表示する。
fn expectMoves(event: model.EventRow, moves: Moves) !void {
    var failed = false;
    inline for (comptime std.enums.values(Attention)) |start_attention| {
        const start: AttentionState = .{ .attention = start_attention, .since = start_time };
        const expected: AttentionState = if (@field(moves, @tagName(start_attention))) |next|
            .{ .attention = next, .since = event_time }
        else
            start;
        const actual = reducer.apply(start, event);
        expectState(expected, actual) catch {
            std.debug.print("開始状態 {s} に {s}（notification_type={?s}, source={?s}, agent_id={?s}）を適用した結果が不一致です\n", .{
                @tagName(start_attention),
                event.event,
                event.notification_type,
                event.session_start_source,
                event.agent_id,
            });
            failed = true;
        };
    }
    if (failed) return error.TestExpectedEqual;
}

test "apply:SessionStart resets every state unless it is a compaction" {
    for ([_]?[]const u8{ "startup", "resume", "clear", "fork", "future-source", null }) |source| {
        try expectMoves(sessionStart(source), .{ .needs_permission = .idle, .needs_input = .idle, .@"error" = .idle, .done = .idle, .working = .idle, .idle = stay, .ended = .idle });
    }
}

test "apply:SessionStart from a compaction changes nothing" {
    try expectMoves(sessionStart("compact"), .{ .needs_permission = stay, .needs_input = stay, .@"error" = stay, .done = stay, .working = stay, .idle = stay, .ended = stay });
}

test "apply:SessionEnd ends every state" {
    try expectMoves(named("SessionEnd"), .{ .needs_permission = .ended, .needs_input = .ended, .@"error" = .ended, .done = .ended, .working = .ended, .idle = .ended, .ended = stay });
}

test "apply:UserPromptSubmit starts work from every live state" {
    try expectMoves(named("UserPromptSubmit"), .{ .needs_permission = .working, .needs_input = .working, .@"error" = .working, .done = .working, .working = stay, .idle = .working, .ended = stay });
}

test "apply:a permission request waits for permission" {
    for ([_]model.EventRow{ named("PermissionRequest"), notification("permission_prompt") }) |event| {
        try expectMoves(event, .{ .needs_permission = stay, .needs_input = .needs_permission, .@"error" = .needs_permission, .done = .needs_permission, .working = .needs_permission, .idle = .needs_permission, .ended = stay });
    }
}

test "apply:a question waits for input" {
    for ([_][]const u8{ "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input" }) |notification_type| {
        try expectMoves(notification(notification_type), .{ .needs_permission = .needs_input, .needs_input = stay, .@"error" = .needs_input, .done = .needs_input, .working = .needs_input, .idle = .needs_input, .ended = stay });
    }
}

test "apply:StopFailure is an error from every live state" {
    try expectMoves(named("StopFailure"), .{ .needs_permission = .@"error", .needs_input = .@"error", .@"error" = stay, .done = .@"error", .working = .@"error", .idle = .@"error", .ended = stay });
}

test "apply:completion is done from every live state" {
    for ([_]model.EventRow{ named("Stop"), notification("agent_completed") }) |event| {
        try expectMoves(event, .{ .needs_permission = .done, .needs_input = .done, .@"error" = .done, .done = stay, .working = .done, .idle = .done, .ended = stay });
    }
}

const work_events = [_][]const u8{ "PreToolUse", "PostToolUse", "PostToolUseFailure", "SubagentStart", "PreCompact" };

test "apply:work by the main agent resumes work but does not undo done" {
    for (work_events) |name| {
        try expectMoves(named(name), .{ .needs_permission = .working, .needs_input = .working, .@"error" = .working, .done = stay, .working = stay, .idle = .working, .ended = stay });
    }
}

test "apply:work by a subagent wakes only idle while the main agent waits" {
    for (work_events) |name| {
        try expectMoves(by(agent_1, named(name)), .{ .needs_permission = stay, .needs_input = stay, .@"error" = stay, .done = stay, .working = stay, .idle = .working, .ended = stay });
    }
}

test "apply:SubagentStop never starts work by itself" {
    try expectMoves(by(agent_1, named("SubagentStop")), .{ .needs_permission = stay, .needs_input = stay, .@"error" = stay, .done = stay, .working = stay, .idle = stay, .ended = stay });
}

test "apply:SubagentStop without an agent only clears the main agent's wait" {
    try expectMoves(named("SubagentStop"), .{ .needs_permission = .working, .needs_input = .working, .@"error" = .working, .done = stay, .working = stay, .idle = stay, .ended = stay });
}

test "apply:unrelated notifications and unknown events change nothing" {
    const events = [_]model.EventRow{
        notification("idle_prompt"),
        notification("auth_success"),
        notification("future_notification"),
        notification(null),
        named("FutureEvent"),
        named("stop"), // 大文字と小文字は区別する
    };
    for (events) |event| {
        try expectMoves(event, .{ .needs_permission = stay, .needs_input = stay, .@"error" = stay, .done = stay, .working = stay, .idle = stay, .ended = stay });
    }
}

// ---------------------------------------------------------------------------
// どのエージェントが起こした状態か（spec §3.2）
// ---------------------------------------------------------------------------

const waiting_states = [_]Attention{ .needs_permission, .needs_input, .@"error" };
const clearing_events = work_events ++ [_][]const u8{"SubagentStop"};

fn expectApply(start: AttentionState, event: model.EventRow, expected: AttentionState) !void {
    const actual = reducer.apply(start, event);
    expectState(expected, actual) catch |err| {
        std.debug.print("開始状態 {s}（agent_id={?s}）に {s}（notification_type={?s}, agent_id={?s}）を適用した結果が不一致です\n", .{
            @tagName(start.attention),
            start.agent_id,
            event.event,
            event.notification_type,
            event.agent_id,
        });
        return err;
    };
}

test "apply:only the agent that caused the wait can clear it" {
    const cases = [_]struct { owner: ?[]const u8, actor: ?[]const u8, clears: bool }{
        .{ .owner = null, .actor = null, .clears = true },
        .{ .owner = agent_1, .actor = agent_1, .clears = true },
        .{ .owner = null, .actor = agent_1, .clears = false },
        .{ .owner = agent_1, .actor = null, .clears = false },
        .{ .owner = agent_1, .actor = agent_2, .clears = false },
    };
    for (cases) |case| {
        for (waiting_states) |attention| {
            for (clearing_events) |name| {
                const start: AttentionState = .{ .attention = attention, .since = start_time, .agent_id = case.owner };
                const expected: AttentionState = if (case.clears) .{ .attention = .working, .since = event_time } else start;
                try expectApply(start, by(case.actor, named(name)), expected);
            }
        }
    }
}

test "apply:agent ids are compared by content, not by address" {
    const allocator = std.testing.allocator;
    const same_text = try allocator.dupe(u8, agent_1);
    defer allocator.free(same_text);

    const start: AttentionState = .{ .attention = .needs_permission, .since = start_time, .agent_id = agent_1 };
    try expectApply(start, by(same_text, named("PostToolUse")), .{ .attention = .working, .since = event_time });
}

test "apply:moving out of a wait forgets its agent" {
    const start: AttentionState = .{ .attention = .needs_permission, .since = start_time, .agent_id = agent_1 };
    const cases = [_]struct { event: model.EventRow, next: Attention }{
        .{ .event = named("UserPromptSubmit"), .next = .working },
        .{ .event = named("Stop"), .next = .done },
        .{ .event = notification("agent_completed"), .next = .done },
        .{ .event = by(agent_1, notification("agent_completed")), .next = .done },
        .{ .event = named("SessionEnd"), .next = .ended },
        .{ .event = sessionStart("clear"), .next = .idle },
        .{ .event = by(agent_1, named("PostToolUse")), .next = .working },
        .{ .event = by(agent_1, named("SubagentStop")), .next = .working },
    };
    for (cases) |case| {
        try expectApply(start, case.event, .{ .attention = case.next, .since = event_time });
    }
}

test "apply:a new wait records the agent that caused it" {
    const start: AttentionState = .{ .attention = .working, .since = start_time };
    const cases = [_]struct { event: model.EventRow, next: Attention }{
        .{ .event = named("PermissionRequest"), .next = .needs_permission },
        .{ .event = notification("permission_prompt"), .next = .needs_permission },
        .{ .event = notification("elicitation_dialog"), .next = .needs_input },
        .{ .event = notification("elicitation_url_dialog"), .next = .needs_input },
        .{ .event = notification("agent_needs_input"), .next = .needs_input },
        .{ .event = named("StopFailure"), .next = .@"error" },
    };
    for (cases) |case| {
        try expectApply(start, by(agent_1, case.event), .{ .attention = case.next, .since = event_time, .agent_id = agent_1 });
    }
}

test "apply:the same wait keeps its first agent and time" {
    const cases = [_]struct { start: AttentionState, event: model.EventRow }{
        .{
            .start = .{ .attention = .needs_permission, .since = start_time, .agent_id = agent_1 },
            .event = by(agent_2, named("PermissionRequest")),
        },
        .{
            .start = .{ .attention = .needs_permission, .since = start_time },
            .event = by(agent_1, named("PermissionRequest")),
        },
        .{
            .start = .{ .attention = .needs_permission, .since = start_time, .agent_id = agent_1 },
            .event = by(agent_2, notification("permission_prompt")),
        },
        .{
            .start = .{ .attention = .needs_input, .since = start_time, .agent_id = agent_1 },
            .event = by(agent_2, notification("agent_needs_input")),
        },
        .{
            .start = .{ .attention = .@"error", .since = start_time, .agent_id = agent_1 },
            .event = by(agent_2, named("StopFailure")),
        },
    };
    for (cases) |case| {
        try expectApply(case.start, case.event, case.start);
    }
}

test "apply:a different wait replaces the agent" {
    const start: AttentionState = .{ .attention = .needs_permission, .since = start_time, .agent_id = agent_1 };
    try expectApply(start, notification("elicitation_dialog"), .{ .attention = .needs_input, .since = event_time });
    try expectApply(start, by(agent_2, notification("elicitation_dialog")), .{ .attention = .needs_input, .since = event_time, .agent_id = agent_2 });
    try expectApply(start, by(agent_2, named("StopFailure")), .{ .attention = .@"error", .since = event_time, .agent_id = agent_2 });
}

test "apply:events that change nothing keep the agent" {
    const start: AttentionState = .{ .attention = .needs_permission, .since = start_time, .agent_id = agent_1 };
    const events = [_]model.EventRow{
        sessionStart("compact"),
        notification("idle_prompt"),
        notification("auth_success"),
        named("FutureEvent"),
    };
    for (events) |event| {
        try expectApply(start, event, start);
    }
}

// ---------------------------------------------------------------------------
// initial と reconcile
// ---------------------------------------------------------------------------

test "initial is idle with no agent" {
    try expectState(.{ .attention = .idle, .since = 7 }, reducer.initial(7));
}

test "initial starts at the given time" {
    try expectState(.{ .attention = .idle, .since = 1234 }, reducer.initial(1234));
}

test "reconcile: an interrupted turn becomes idle" {
    const state: AttentionState = .{ .attention = .working, .since = 1000 };
    try expectState(.{ .attention = .idle, .since = 2000 }, reducer.reconcile(state, .idle, 2000, 5000));
}

test "reconcile: the idle time comes from the status, not from now" {
    const state: AttentionState = .{ .attention = .working, .since = 40 };
    try expectState(.{ .attention = .idle, .since = 500 }, reducer.reconcile(state, .idle, 500, 90000));
}

test "reconcile: exactly three seconds is enough" {
    const state: AttentionState = .{ .attention = .working, .since = 1000 };
    try expectState(.{ .attention = .idle, .since = 2000 }, reducer.reconcile(state, .idle, 2000, 5000));
}

test "reconcile: just under three seconds is not enough" {
    const state: AttentionState = .{ .attention = .working, .since = 1000 };
    try expectState(state, reducer.reconcile(state, .idle, 2000, 4999));
}

test "reconcile: three seconds are counted from the status time" {
    const state: AttentionState = .{ .attention = .working, .since = 1000 };
    try expectState(state, reducer.reconcile(state, .idle, 8000, 10999));
    try expectState(.{ .attention = .idle, .since = 8000 }, reducer.reconcile(state, .idle, 8000, 11000));
}

test "reconcile: a status from the future is not enough" {
    const state: AttentionState = .{ .attention = .working, .since = 1000 };
    try expectState(state, reducer.reconcile(state, .idle, 9000, 2000));
}

test "reconcile: a status one millisecond newer than the turn counts" {
    const state: AttentionState = .{ .attention = .working, .since = 1000 };
    try expectState(.{ .attention = .idle, .since = 1001 }, reducer.reconcile(state, .idle, 1001, 9000));
}

test "reconcile: a status older than the turn is ignored" {
    const state: AttentionState = .{ .attention = .working, .since = 1000 };
    try expectState(state, reducer.reconcile(state, .idle, 1000, 9000));
    try expectState(state, reducer.reconcile(state, .idle, 999, 9000));
}

test "reconcile: busy, unknown and missing status change nothing" {
    const state: AttentionState = .{ .attention = .working, .since = 1000 };
    try expectState(state, reducer.reconcile(state, .busy, 2000, 9000));
    try expectState(state, reducer.reconcile(state, .unknown, 2000, 9000));
    try expectState(state, reducer.reconcile(state, .idle, null, 9000));
}

test "reconcile: only working is corrected" {
    for ([_]Attention{ .needs_permission, .needs_input, .@"error", .done, .idle, .ended }) |attention| {
        const state: AttentionState = .{ .attention = attention, .since = 1000 };
        try expectState(state, reducer.reconcile(state, .idle, 2000, 9000));
    }
}

test "reconcile: a wait keeps its agent" {
    const state: AttentionState = .{ .attention = .needs_permission, .since = 1000, .agent_id = agent_1 };
    try expectState(state, reducer.reconcile(state, .idle, 2000, 9000));
}

comptime {
    std.testing.refAllDecls(reducer);
}
