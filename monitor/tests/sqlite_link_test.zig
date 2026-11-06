const std = @import("std");
const cc_ran = @import("cc_ran");

const c = cc_ran.sqlite_c;

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

    try std.testing.expectEqual(c.SQLITE_OK, c.sqlite3_exec(db, cc_ran.init_sql, null, null, null));
}

comptime {
    std.testing.refAllDecls(c);
}
