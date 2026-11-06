const std = @import("std");
const cc_ran = @import("cc_ran");
const support = @import("support.zig");

const model = cc_ran.model;

/// 列挙型のすべての値が SQL の CHECK 制約に現れ、値の数が期待どおりであることを確かめる。
fn expectEnumMatchesSql(comptime E: type, sql: []const u8, expected_count: usize) !void {
    const values = std.enums.values(E);
    try std.testing.expectEqual(expected_count, values.len);
    var buffer: [64]u8 = undefined;
    for (values) |value| {
        const quoted = try std.fmt.bufPrint(&buffer, "'{s}'", .{@tagName(value)});
        if (std.mem.indexOf(u8, sql, quoted) == null) {
            std.debug.print("SQL に {s} がありません\n", .{quoted});
            return error.TestExpectedEqual;
        }
    }
}

test "model enums match the contract schema" {
    const gpa = std.testing.allocator;
    const sql = try support.readContract(gpa, "schema/001_init.sql");
    defer gpa.free(sql);

    try expectEnumMatchesSql(model.Attention, sql, 7);
    try expectEnumMatchesSql(model.ContextLevel, sql, 4);
    try expectEnumMatchesSql(model.WindowSource, sql, 5);
    try expectEnumMatchesSql(model.Kind, sql, 3);
}

test "embedded contracts are the files in the repository" {
    const gpa = std.testing.allocator;
    const sql = try support.readContract(gpa, "schema/001_init.sql");
    defer gpa.free(sql);
    const models = try support.readContract(gpa, "models.json");
    defer gpa.free(models);

    try std.testing.expectEqualStrings(sql, cc_ran.init_sql);
    try std.testing.expectEqualStrings(models, cc_ran.models_json);
}

comptime {
    std.testing.refAllDecls(model);
}
