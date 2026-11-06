const std = @import("std");
const c = @import("sqlite_c");

test "sqlite is linked and can open an in-memory database" {
    var db: ?*c.sqlite3 = null;
    const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
    defer _ = c.sqlite3_close_v2(db);

    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(":memory:", &db, flags, null));
}

test "contract schema applies through the embedded sql" {
    var db: ?*c.sqlite3 = null;
    const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
    defer _ = c.sqlite3_close_v2(db);
    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_open_v2(":memory:", &db, flags, null));

    const init_sql: [:0]const u8 = @embedFile("init_sql");

    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, init_sql, null, null, null));
}

comptime {
    std.testing.refAllDecls(c);
}
