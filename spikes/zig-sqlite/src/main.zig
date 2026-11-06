// spike：Task 11 で削除する。プロダクトコードではない。
// 確かめること：SQLite のビルドとリンク、WAL、スキーマの適用、日本語を含むパス、1 回の所要時間。
const std = @import("std");
const c = @import("sqlite_c");

const init_sql = @embedFile("init_sql");

fn check(db: ?*c.sqlite3, rc: c_int, what: []const u8) void {
    if (rc != c.SQLITE_OK and rc != c.SQLITE_ROW and rc != c.SQLITE_DONE) {
        std.debug.print("{s}: rc={d} {s}\n", .{ what, rc, c.sqlite3_errmsg(db) });
        std.process.exit(1);
    }
}

fn exec(db: ?*c.sqlite3, sql: [*:0]const u8) void {
    check(db, c.sqlite3_exec(db, sql, null, null, null), "exec");
}

fn int64(db: ?*c.sqlite3, sql: []const u8) i64 {
    var stmt: ?*c.sqlite3_stmt = null;
    check(db, c.sqlite3_prepare_v2(db, sql.ptr, @intCast(sql.len), &stmt, null), "prepare");
    defer _ = c.sqlite3_finalize(stmt);
    check(db, c.sqlite3_step(stmt), "step");
    return c.sqlite3_column_int64(stmt, 0);
}

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2) return 64;

    var db: ?*c.sqlite3 = null;
    const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE;
    check(db, c.sqlite3_open_v2(args[1].ptr, &db, flags, null), "open");
    defer _ = c.sqlite3_close_v2(db);

    check(db, c.sqlite3_busy_timeout(db, 500), "busy_timeout");
    exec(db, "PRAGMA journal_mode=WAL");
    exec(db, "PRAGMA synchronous=NORMAL");
    if (int64(db, "PRAGMA user_version") == 0) exec(db, init_sql);

    exec(db, "BEGIN IMMEDIATE");
    const insert = "INSERT INTO events(received_at, origin, source, session_id, event, cwd) VALUES (1, 'local', 'hook', 's', 'Stop', ?1)";
    var stmt: ?*c.sqlite3_stmt = null;
    check(db, c.sqlite3_prepare_v2(db, insert, insert.len, &stmt, null), "prepare");
    const cwd = "/ホーム/日本語";
    check(db, c.sqlite3_bind_text(stmt, 1, cwd, cwd.len, c.SQLITE_TRANSIENT), "bind");
    check(db, c.sqlite3_step(stmt), "insert");
    _ = c.sqlite3_finalize(stmt);
    exec(db, "COMMIT");

    const select = "SELECT cwd FROM events ORDER BY seq DESC LIMIT 1";
    check(db, c.sqlite3_prepare_v2(db, select, select.len, &stmt, null), "prepare");
    defer _ = c.sqlite3_finalize(stmt);
    check(db, c.sqlite3_step(stmt), "select");
    const got = std.mem.span(c.sqlite3_column_text(stmt, 0).?);
    if (!std.mem.eql(u8, got, cwd)) {
        std.debug.print("round trip mismatch: {s}\n", .{got});
        return 2;
    }

    std.debug.print("ok events={d} user_version={d}\n", .{
        int64(db, "SELECT COUNT(*) FROM events"),
        int64(db, "PRAGMA user_version"),
    });
    return 0;
}
