const std = @import("std");
const cc_ran = @import("cc_ran");
const support = @import("support.zig");

const context = cc_ran.context;
const config = cc_ran.config;
const model = cc_ran.model;
const Window = context.Window;

/// models.json と違う値を持つ表。200,000 や 1,000,000 を決め打ちした実装を見分けるために使う。
const custom_table_json =
    \\{
    \\  "version": 1,
    \\  "verified_at": "2026-11-08",
    \\  "sources": ["test"],
    \\  "default_window": 128000,
    \\  "one_million": 2000000,
    \\  "models": [
    \\    { "id": "claude-test-small", "window": 64000 },
    \\    { "id": "claude-test-large", "window": 2000000 }
    \\  ]
    \\}
;

const Options = struct {
    disable_1m: bool = false,
    config_json: []const u8 = "{}",
    table_json: []const u8 = cc_ran.models_json,
};

fn resolve(model_id: ?[]const u8, used: ?u64, options: Options) !Window {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const table = try context.ModelTable.parse(arena, options.table_json);
    const settings = try config.parse(arena, options.config_json);
    return context.resolveWindow(table, &settings, model_id, used, options.disable_1m);
}

fn expectWindow(tokens: ?u64, source: model.WindowSource, actual: Window) !void {
    try std.testing.expectEqual(Window{ .tokens = tokens, .source = source }, actual);
}

fn levelOf(used: ?u64, window: ?u64, config_json: []const u8) !model.ContextLevel {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const settings = try config.parse(arena_state.allocator(), config_json);
    return context.level(used, window, &settings);
}

// ---------------------------------------------------------------------------
// stripDateSuffix
// ---------------------------------------------------------------------------

test "stripDateSuffix: removes a trailing -YYYYMMDD" {
    try std.testing.expectEqualStrings("claude-haiku-4-5", context.stripDateSuffix("claude-haiku-4-5-20251001"));
    try std.testing.expectEqualStrings("claude-opus-4", context.stripDateSuffix("claude-opus-4-20250514"));
}

test "stripDateSuffix: keeps an id without a date" {
    try std.testing.expectEqualStrings("claude-opus-5-5", context.stripDateSuffix("claude-opus-5-5"));
    try std.testing.expectEqualStrings("claude-opus-4-1", context.stripDateSuffix("claude-opus-4-1"));
    try std.testing.expectEqualStrings("claude-foo-123", context.stripDateSuffix("claude-foo-123"));
    try std.testing.expectEqualStrings("", context.stripDateSuffix(""));
}

test "stripDateSuffix: only exactly eight digits after a hyphen count as a date" {
    try std.testing.expectEqualStrings("claude-x-2025100", context.stripDateSuffix("claude-x-2025100"));
    try std.testing.expectEqualStrings("claude-x-202510011", context.stripDateSuffix("claude-x-202510011"));
    try std.testing.expectEqualStrings("claude-x-2025100a", context.stripDateSuffix("claude-x-2025100a"));
    try std.testing.expectEqualStrings("claude-x20251001", context.stripDateSuffix("claude-x20251001"));
}

// ---------------------------------------------------------------------------
// ModelTable
// ---------------------------------------------------------------------------

test "ModelTable.parse: reads the sizes from models.json" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const table = try context.ModelTable.parse(arena_state.allocator(), cc_ran.models_json);
    try std.testing.expectEqual(@as(u64, 200_000), table.default_window);
    try std.testing.expectEqual(@as(u64, 1_000_000), table.one_million);
}

test "ModelTable.parse: reads the sizes from another table" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const table = try context.ModelTable.parse(arena_state.allocator(), custom_table_json);
    try std.testing.expectEqual(@as(u64, 128_000), table.default_window);
    try std.testing.expectEqual(@as(u64, 2_000_000), table.one_million);
    try std.testing.expectEqual(@as(?u64, 64_000), table.lookup("claude-test-small"));
}

test "ModelTable.lookup: finds every model in models.json" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const table = try context.ModelTable.parse(arena, cc_ran.models_json);

    // 期待値は ModelTable を使わず、models.json を直接読んで作る。
    const bytes = try support.readContract(arena, "models.json");
    const root = (try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{})).object;
    const models = root.get("models").?.array.items;
    try std.testing.expect(models.len > 0);
    for (models) |entry| {
        const id = entry.object.get("id").?.string;
        const window: u64 = @intCast(entry.object.get("window").?.integer);
        std.testing.expectEqual(@as(?u64, window), table.lookup(id)) catch |err| {
            std.debug.print("models.json の {s} が見つからないか、値が違います\n", .{id});
            return err;
        };
    }
}

test "ModelTable.lookup: does not match by prefix" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const table = try context.ModelTable.parse(arena_state.allocator(), cc_ran.models_json);
    try std.testing.expectEqual(@as(?u64, null), table.lookup("claude-opus-5-7"));
    try std.testing.expectEqual(@as(?u64, null), table.lookup("claude-opus-5-5-extra"));
    try std.testing.expectEqual(@as(?u64, null), table.lookup("claude-opus"));
    try std.testing.expectEqual(@as(?u64, null), table.lookup(""));
}

// ---------------------------------------------------------------------------
// resolveWindow（spec §4.2 の優先順）
// ---------------------------------------------------------------------------

test "resolveWindow: a model in the table is builtin" {
    try expectWindow(1_000_000, .builtin, try resolve("claude-opus-5-5", 717_000, .{}));
    try expectWindow(200_000, .builtin, try resolve("claude-opus-4-6", 150_000, .{}));
    try expectWindow(200_000, .builtin, try resolve("claude-opus-4-6", null, .{}));
}

test "resolveWindow: the date suffix is removed before the lookup" {
    try expectWindow(200_000, .builtin, try resolve("claude-haiku-4-5-20251001", 10, .{}));
    try expectWindow(200_000, .builtin, try resolve("claude-opus-4-20250514", null, .{}));
}

test "resolveWindow: usage over the table value is observed as one million" {
    try expectWindow(1_000_000, .observed, try resolve("claude-opus-4-6", 500_000, .{}));
}

test "resolveWindow: usage equal to the table value is not over it" {
    try expectWindow(200_000, .builtin, try resolve("claude-opus-4-6", 200_000, .{}));
    try expectWindow(1_000_000, .observed, try resolve("claude-opus-4-6", 200_001, .{}));
}

test "resolveWindow: a model outside the table is a fallback" {
    try expectWindow(200_000, .fallback, try resolve("claude-future-9", 40_000, .{}));
    try expectWindow(200_000, .fallback, try resolve("claude-future-9", null, .{}));
    try expectWindow(1_000_000, .observed, try resolve("claude-future-9", 500_000, .{}));
}

test "resolveWindow: a newer version is not matched by prefix" {
    try expectWindow(200_000, .fallback, try resolve("claude-opus-5-7", 10, .{}));
}

test "resolveWindow: the sizes come from the table, not from constants" {
    const custom: Options = .{ .table_json = custom_table_json };
    try expectWindow(128_000, .fallback, try resolve("claude-future-9", 1_000, custom));
    try expectWindow(64_000, .builtin, try resolve("claude-test-small", 64_000, custom));
    try expectWindow(2_000_000, .observed, try resolve("claude-test-small", 64_001, custom));
    try expectWindow(2_000_000, .observed, try resolve("claude-future-9", 128_001, custom));
    try expectWindow(128_000, .fallback, try resolve(null, 5, custom));
}

test "resolveWindow: a config override wins over everything" {
    const override: Options = .{ .config_json = "{\"models\": {\"claude-opus-4-6\": 123456, \"claude-future-9\": 98765}}" };
    try expectWindow(123_456, .config, try resolve("claude-opus-4-6", 10, override));
    try expectWindow(123_456, .config, try resolve("claude-opus-4-6", 500_000, override));
    try expectWindow(98_765, .config, try resolve("claude-future-9", null, override));
}

test "resolveWindow: disable_1m caps the table and the observed size" {
    const disabled: Options = .{ .disable_1m = true };
    try expectWindow(200_000, .builtin, try resolve("claude-opus-5-5", 10, disabled));
    try expectWindow(200_000, .builtin, try resolve("claude-opus-5-5", 500_000, disabled));
    try expectWindow(200_000, .builtin, try resolve("claude-opus-4-6", 500_000, disabled));
    try expectWindow(200_000, .fallback, try resolve("claude-future-9", 500_000, disabled));
    try expectWindow(200_000, .fallback, try resolve(null, 500_000, disabled));
}

test "resolveWindow: disable_1m caps to the table's default size" {
    try expectWindow(128_000, .builtin, try resolve("claude-test-large", 10, .{ .disable_1m = true, .table_json = custom_table_json }));
}

test "resolveWindow: a config override wins over disable_1m" {
    const both: Options = .{ .disable_1m = true, .config_json = "{\"models\": {\"claude-opus-5-5\": 1000000}}" };
    try expectWindow(1_000_000, .config, try resolve("claude-opus-5-5", 10, both));
}

test "resolveWindow: without a model the usage decides" {
    try expectWindow(null, .unknown, try resolve(null, null, .{}));
    try expectWindow(200_000, .fallback, try resolve(null, 10, .{}));
    try expectWindow(1_000_000, .observed, try resolve(null, 500_000, .{}));
}

// ---------------------------------------------------------------------------
// level（spec §4.4）
// ---------------------------------------------------------------------------

test "level: the default thresholds are 70 and 90 percent" {
    try std.testing.expectEqual(model.ContextLevel.ok, try levelOf(0, 200_000, "{}"));
    try std.testing.expectEqual(model.ContextLevel.ok, try levelOf(139_999, 200_000, "{}"));
    try std.testing.expectEqual(model.ContextLevel.warn, try levelOf(140_000, 200_000, "{}"));
    try std.testing.expectEqual(model.ContextLevel.warn, try levelOf(179_999, 200_000, "{}"));
    try std.testing.expectEqual(model.ContextLevel.critical, try levelOf(180_000, 200_000, "{}"));
}

test "level: the thresholds scale with a one million window" {
    try std.testing.expectEqual(model.ContextLevel.ok, try levelOf(699_999, 1_000_000, "{}"));
    try std.testing.expectEqual(model.ContextLevel.warn, try levelOf(700_000, 1_000_000, "{}"));
    try std.testing.expectEqual(model.ContextLevel.warn, try levelOf(899_999, 1_000_000, "{}"));
    try std.testing.expectEqual(model.ContextLevel.critical, try levelOf(900_000, 1_000_000, "{}"));
}

test "level: usage over the window is critical" {
    try std.testing.expectEqual(model.ContextLevel.critical, try levelOf(300_000, 200_000, "{}"));
}

test "level: missing usage or window is unknown" {
    try std.testing.expectEqual(model.ContextLevel.unknown, try levelOf(null, 200_000, "{}"));
    try std.testing.expectEqual(model.ContextLevel.unknown, try levelOf(100_000, null, "{}"));
    try std.testing.expectEqual(model.ContextLevel.unknown, try levelOf(null, null, "{}"));
    try std.testing.expectEqual(model.ContextLevel.unknown, try levelOf(100_000, 0, "{}"));
}

test "level: the thresholds come from the config" {
    const custom = "{\"thresholds\": {\"warn\": 0.5, \"critical\": 0.8}}";
    try std.testing.expectEqual(model.ContextLevel.ok, try levelOf(99_999, 200_000, custom));
    try std.testing.expectEqual(model.ContextLevel.warn, try levelOf(100_000, 200_000, custom));
    try std.testing.expectEqual(model.ContextLevel.warn, try levelOf(159_999, 200_000, custom));
    try std.testing.expectEqual(model.ContextLevel.critical, try levelOf(160_000, 200_000, custom));
}

comptime {
    std.testing.refAllDecls(context);
}
