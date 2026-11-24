const std = @import("std");
const cc_ran = @import("cc_ran");

const config = cc_ran.config;
const Config = config.Config;

/// テストの中で読んだ設定。arena は呼び出し側が解放する。
fn parseIn(arena_state: *std.heap.ArenaAllocator, json: []const u8) !Config {
    return config.parse(arena_state.allocator(), json);
}

fn expectDefaults(settings: Config) !void {
    try std.testing.expectEqual(@as(f64, 0.70), settings.warn);
    try std.testing.expectEqual(@as(f64, 0.90), settings.critical);
    try std.testing.expectEqual(@as(i64, 300_000), settings.ended_grace_ms);
    try std.testing.expectEqual(@as(?u64, null), settings.modelOverride("claude-opus-4-6"));
}

test "config.parse: an empty object gives the defaults" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try expectDefaults(try parseIn(&arena_state, "{}"));
}

test "config.parse: reads the example in spec 5.1" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const settings = try parseIn(&arena_state,
        \\{
        \\  "thresholds": { "warn": 0.70, "critical": 0.90 },
        \\  "models": { "claude-opus-4-6": 1000000 },
        \\  "endedGraceSeconds": 300
        \\}
    );
    try std.testing.expectEqual(@as(f64, 0.70), settings.warn);
    try std.testing.expectEqual(@as(f64, 0.90), settings.critical);
    try std.testing.expectEqual(@as(i64, 300_000), settings.ended_grace_ms);
    try std.testing.expectEqual(@as(?u64, 1_000_000), settings.modelOverride("claude-opus-4-6"));
}

test "config.parse: reads values other than the defaults" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const settings = try parseIn(&arena_state,
        \\{
        \\  "thresholds": { "warn": 0.6, "critical": 0.85 },
        \\  "models": { "claude-test-a": 123456, "claude-test-b": 64000 },
        \\  "endedGraceSeconds": 60
        \\}
    );
    try std.testing.expectEqual(@as(f64, 0.6), settings.warn);
    try std.testing.expectEqual(@as(f64, 0.85), settings.critical);
    try std.testing.expectEqual(@as(?u64, 123_456), settings.modelOverride("claude-test-a"));
    try std.testing.expectEqual(@as(?u64, 64_000), settings.modelOverride("claude-test-b"));
}

test "config.parse: endedGraceSeconds becomes milliseconds" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectEqual(@as(i64, 60_000), (try parseIn(&arena_state, "{\"endedGraceSeconds\": 60}")).ended_grace_ms);
    try std.testing.expectEqual(@as(i64, 1_800_000), (try parseIn(&arena_state, "{\"endedGraceSeconds\": 1800}")).ended_grace_ms);
}

test "config.parse: a partial thresholds object keeps the other default" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const only_warn = try parseIn(&arena_state, "{\"thresholds\": {\"warn\": 0.6}}");
    try std.testing.expectEqual(@as(f64, 0.6), only_warn.warn);
    try std.testing.expectEqual(@as(f64, 0.90), only_warn.critical);

    const only_critical = try parseIn(&arena_state, "{\"thresholds\": {\"critical\": 0.95}}");
    try std.testing.expectEqual(@as(f64, 0.70), only_critical.warn);
    try std.testing.expectEqual(@as(f64, 0.95), only_critical.critical);
}

test "config.parse: JSON that cannot be read gives the defaults" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const inputs = [_][]const u8{
        "",
        "{",
        "not json",
        "{\"thresholds\": {\"warn\": }}",
        "[]",
    };
    for (inputs) |json| {
        expectDefaults(try parseIn(&arena_state, json)) catch |err| {
            std.debug.print("入力 \"{s}\" で既定値になりませんでした\n", .{json});
            return err;
        };
    }
}

test "config.parse: unknown keys are ignored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const settings = try parseIn(&arena_state,
        \\{
        \\  "futureOption": true,
        \\  "thresholds": { "warn": 0.6, "note": "x" },
        \\  "models": {}
        \\}
    );
    try std.testing.expectEqual(@as(f64, 0.6), settings.warn);
    try std.testing.expectEqual(@as(f64, 0.90), settings.critical);
    try std.testing.expectEqual(@as(i64, 300_000), settings.ended_grace_ms);
}

test "Config.modelOverride: only an exact id matches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const settings = try parseIn(&arena_state, "{\"models\": {\"claude-opus-4-6\": 123456}}");
    try std.testing.expectEqual(@as(?u64, 123_456), settings.modelOverride("claude-opus-4-6"));
    try std.testing.expectEqual(@as(?u64, null), settings.modelOverride("claude-opus-4"));
    try std.testing.expectEqual(@as(?u64, null), settings.modelOverride("claude-opus-4-6-extra"));
    try std.testing.expectEqual(@as(?u64, null), settings.modelOverride(""));
}

comptime {
    std.testing.refAllDecls(config);
}
