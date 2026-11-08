const std = @import("std");
const cc_ran = @import("cc_ran");

const rank = cc_ran.rank;
const model = cc_ran.model;
const RankInput = rank.RankInput;

fn input(session_id: []const u8, attention: model.Attention, level: model.ContextLevel, last_activity_at: i64) RankInput {
    return .{ .session_id = session_id, .attention = attention, .level = level, .last_activity_at = last_activity_at };
}

/// inputs[i] の表示順が expected[i] になることを確かめる。
fn expectRanks(expected: []const i64, inputs: []const RankInput) !void {
    const gpa = std.testing.allocator;
    const out = try gpa.alloc(i64, inputs.len);
    defer gpa.free(out);
    try rank.assign(gpa, inputs, out);
    try std.testing.expectEqualSlices(i64, expected, out);
}

test "rank.assign: an empty list succeeds" {
    try expectRanks(&.{}, &.{});
}

test "rank.assign: a single session is first" {
    try expectRanks(&.{0}, &.{input("s", .working, .ok, 100)});
}

test "rank.assign: attention comes first, in the order of spec 3.1" {
    try expectRanks(&.{ 3, 6, 1, 4, 0, 5, 2 }, &.{
        input("s7", .done, .ok, 100),
        input("s6", .ended, .ok, 100),
        input("s5", .needs_input, .ok, 100),
        input("s4", .working, .ok, 100),
        input("s3", .needs_permission, .ok, 100),
        input("s2", .idle, .ok, 100),
        input("s1", .@"error", .ok, 100),
    });
}

test "rank.assign: within the same attention, critical, warn, ok, then unknown" {
    // ContextLevel の宣言順（ok, warn, critical, unknown）とは違う順序になる。
    try expectRanks(&.{ 2, 3, 0, 1 }, &.{
        input("s4", .working, .ok, 100),
        input("s3", .working, .unknown, 100),
        input("s2", .working, .critical, 100),
        input("s1", .working, .warn, 100),
    });
}

test "rank.assign: attention outranks the context level" {
    try expectRanks(&.{ 2, 0, 3, 1 }, &.{
        input("s4", .idle, .critical, 100),
        input("s3", .needs_permission, .unknown, 100),
        input("s2", .ended, .critical, 100),
        input("s1", .working, .unknown, 100),
    });
}

test "rank.assign: the context level outranks recent activity" {
    try expectRanks(&.{ 1, 0 }, &.{
        input("s2", .working, .ok, 900),
        input("s1", .working, .warn, 100),
    });
}

test "rank.assign: newer activity comes first" {
    try expectRanks(&.{ 2, 0, 1 }, &.{
        input("s3", .done, .ok, 100),
        input("s2", .done, .ok, 300),
        input("s1", .done, .ok, 200),
    });
}

test "rank.assign: the session id breaks a full tie in ascending order" {
    try expectRanks(&.{ 1, 2, 0 }, &.{
        input("b", .done, .ok, 100),
        input("c", .done, .ok, 100),
        input("a", .done, .ok, 100),
    });
}

comptime {
    std.testing.refAllDecls(rank);
}
