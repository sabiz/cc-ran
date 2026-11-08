//! Attention state の状態遷移（spec §3）。I/O を持たない純粋な関数だけを置く。
const std = @import("std");
const model = @import("model.zig");

const AttentionState = model.AttentionState;
const Attention = model.Attention;
const EventRow = model.EventRow;
const FileStatus = model.FileStatus;
const Event = enum { SessionStart, SessionEnd, UserPromptSubmit, PermissionRequest, Notification, StopFailure, Stop, SubagentStop, PreToolUse, PostToolUse, PostToolUseFailure, SubagentStart, PreCompact };
const NotificationType = enum { permission_prompt, elicitation_dialog, elicitation_url_dialog, agent_needs_input, agent_completed };

/// 新しいセッションの最初の状態（idle）。
pub fn initial(at: i64) AttentionState {
    return .{ .attention = .idle, .since = at };
}

/// イベントを 1 件適用した後の状態を返す。
/// 状態が変わらないときは since も agent_id も変えない。遷移の規則は plan 01 の Task 2 の表のとおり。
pub fn apply(state: AttentionState, event: EventRow) AttentionState {
    const event_type = std.meta.stringToEnum(Event, event.event) orelse return state;
    if (event_type == .SessionStart) {
        if (std.mem.eql(u8, "compact", event.session_start_source orelse "")) {
            return state;
        }
        return moveTo(state, .idle, event.received_at, null);
    }
    if (state.attention == .ended) {
        return state;
    }
    return switch (event_type) {
        .SessionEnd => moveTo(state, .ended, event.received_at, null),
        .UserPromptSubmit => moveTo(state, .working, event.received_at, null),
        .PermissionRequest => moveTo(state, .needs_permission, event.received_at, event.agent_id),
        .Notification => blk: {
            const notification_type = event.notification_type orelse return state;
            break :blk switch (std.meta.stringToEnum(NotificationType, notification_type) orelse return state) {
                .permission_prompt => moveTo(state, .needs_permission, event.received_at, event.agent_id),
                .elicitation_dialog, .elicitation_url_dialog, .agent_needs_input => moveTo(state, .needs_input, event.received_at, event.agent_id),
                .agent_completed => moveTo(state, .done, event.received_at, null),
            };
        },
        .StopFailure => moveTo(state, .@"error", event.received_at, event.agent_id),
        .Stop => moveTo(state, .done, event.received_at, null),
        .PreToolUse, .PostToolUse, .PostToolUseFailure, .SubagentStart, .PreCompact => switch (state.attention) {
            .idle => moveTo(state, .working, event.received_at, null),
            .needs_permission, .needs_input, .@"error" => if (sameAgent(state.agent_id, event.agent_id)) moveTo(state, .working, event.received_at, null) else state,
            .done, .working, .ended => state,
        },
        .SubagentStop => if ((state.attention == .needs_permission or
            state.attention == .needs_input or
            state.attention == .@"error") and sameAgent(state.agent_id, event.agent_id)) moveTo(state, .working, event.received_at, null) else state,
        .SessionStart => unreachable,
    };
}

/// attention_state を target_attention に移す。すでに target_attention なら since も agent_id も変えない。
/// agent_id には、その状態を起こしたエージェントを渡す（記録しない状態なら null）。
fn moveTo(attention_state: AttentionState, target_attention: Attention, at: i64, agent_id: ?[]const u8) AttentionState {
    if (attention_state.attention == target_attention) {
        return attention_state;
    }
    return .{ .attention = target_attention, .since = at, .agent_id = agent_id };
}

fn sameAgent(state_agent_id: ?[]const u8, event_agent_id: ?[]const u8) bool {
    const st_agent_id = state_agent_id orelse return event_agent_id == null;
    const ev_agent_id = event_agent_id orelse return false;
    return std.mem.eql(u8, st_agent_id, ev_agent_id);
}

/// Stop はユーザーの中断では発火しないので、セッションファイルの status で working を補正する。
/// working かつ status が idle かつ status_updated_at > since かつ now - status_updated_at >= 3000 のとき、
/// idle（since = status_updated_at）を返す。それ以外は変えない。
pub fn reconcile(state: AttentionState, status: FileStatus, status_updated_at: ?i64, now: i64) AttentionState {
    const updated_at = status_updated_at orelse return state;
    if (state.attention == .working and
        status == .idle and
        updated_at > state.since and
        now - updated_at >= 3000)
    {
        return .{ .attention = .idle, .since = updated_at };
    }
    return state;
}
