//! 一覧の並び順（spec §3.3）。I/O を持たない純粋な関数だけを置く。

const std = @import("std");
const model = @import("model.zig");

const Attention = model.Attention;
const ContextLevel = model.ContextLevel;

pub const RankInput = struct {
    session_id: []const u8,
    attention: Attention,
    level: ContextLevel,
    last_activity_at: i64,
};

/// out[i] に inputs[i] の表示順（0 始まり）を入れる。out の長さは inputs と同じ。
/// 順序：attention の重さ → コンテキストの段階 → last_activity_at の新しい順 → session_id の昇順。
pub fn assign(gpa: std.mem.Allocator, inputs: []const RankInput, out: []i64) !void {
    // 表示順に並べた入力の添字。sorted_indices[p] = k なら、inputs[k] は p 番目に表示される。
    const sorted_indices = try gpa.alloc(usize, inputs.len);
    defer gpa.free(sorted_indices);
    for (sorted_indices, 0..) |*index, i| {
        index.* = i;
    }
    const Inputs = struct {
        value: []const RankInput,
    };
    std.mem.sort(usize, sorted_indices, Inputs{ .value = inputs }, struct {
        fn compareLevel(a_level: ContextLevel, b_level: ContextLevel) ?bool {
            if (a_level == b_level) {
                return null;
            }
            switch (a_level) {
                .critical => return true,
                .warn => return b_level != .critical,
                .ok => return b_level != .critical and b_level != .warn,
                .unknown => return false,
            }
        }

        pub fn compare(ctx_inputs: Inputs, a: usize, b: usize) bool {
            const input_a = ctx_inputs.value[a];
            const input_b = ctx_inputs.value[b];
            const attention_order = std.math.order(@backingInt(input_a.attention), @backingInt(input_b.attention));
            if (attention_order != .eq) {
                return attention_order == .lt;
            }
            if (compareLevel(input_a.level, input_b.level)) |result| {
                return result;
            }

            const last_activity_at_order = std.math.order(input_a.last_activity_at, input_b.last_activity_at);
            if (last_activity_at_order != .eq) {
                return last_activity_at_order == .gt;
            }
            return std.mem.order(u8, input_a.session_id, input_b.session_id) == .lt;
        }
    }.compare);
    for (sorted_indices, 0..) |index, position| {
        out[index] = @intCast(position);
    }
}
