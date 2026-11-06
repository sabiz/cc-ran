//! SQLite の C API の宣言だけを置く（@cImport は Zig 0.17 で削除された）。
//! ここにはロジックを書かない。ラッパーは store に実装する。

const std = @import("std");

pub const sqlite3 = opaque {};
pub const sqlite3_stmt = opaque {};
/// SQLITE_TRANSIENT の値（-1）は関数のアラインメントを満たさないので、align(1) にする。
pub const Destructor = ?*align(1) const fn (?*anyopaque) callconv(.c) void;
pub const ExecCallback = ?*const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int;

pub const SQLITE_OK: c_int = 0;
pub const SQLITE_BUSY: c_int = 5;
pub const SQLITE_LOCKED: c_int = 6;
pub const SQLITE_CANTOPEN: c_int = 14;
pub const SQLITE_ROW: c_int = 100;
pub const SQLITE_DONE: c_int = 101;

pub const SQLITE_OPEN_READONLY: c_int = 0x00000001;
pub const SQLITE_OPEN_READWRITE: c_int = 0x00000002;
pub const SQLITE_OPEN_CREATE: c_int = 0x00000004;
pub const SQLITE_OPEN_FULLMUTEX: c_int = 0x00010000;

pub const SQLITE_INTEGER: c_int = 1;
pub const SQLITE_FLOAT: c_int = 2;
pub const SQLITE_TEXT: c_int = 3;
pub const SQLITE_BLOB: c_int = 4;
pub const SQLITE_NULL: c_int = 5;

pub const SQLITE_CHECKPOINT_PASSIVE: c_int = 0;
pub const SQLITE_CHECKPOINT_TRUNCATE: c_int = 3;

/// SQLite に文字列をコピーさせる指定。C では `(sqlite3_destructor_type)-1`。
pub const SQLITE_TRANSIENT: Destructor = @ptrFromInt(std.math.maxInt(usize));

pub extern fn sqlite3_open_v2(filename: [*:0]const u8, pp_db: *?*sqlite3, flags: c_int, z_vfs: ?[*:0]const u8) c_int;
pub extern fn sqlite3_close_v2(db: ?*sqlite3) c_int;
pub extern fn sqlite3_exec(db: ?*sqlite3, sql: [*:0]const u8, callback: ExecCallback, arg: ?*anyopaque, errmsg: ?*?[*:0]u8) c_int;
pub extern fn sqlite3_prepare_v2(db: ?*sqlite3, z_sql: [*]const u8, n_byte: c_int, pp_stmt: *?*sqlite3_stmt, pz_tail: ?*?[*]const u8) c_int;
pub extern fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, index: c_int, value: i64) c_int;
pub extern fn sqlite3_bind_text(stmt: ?*sqlite3_stmt, index: c_int, value: [*]const u8, n_bytes: c_int, destructor: Destructor) c_int;
pub extern fn sqlite3_bind_null(stmt: ?*sqlite3_stmt, index: c_int) c_int;
pub extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, column: c_int) i64;
pub extern fn sqlite3_column_text(stmt: ?*sqlite3_stmt, column: c_int) ?[*:0]const u8;
pub extern fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, column: c_int) c_int;
pub extern fn sqlite3_column_type(stmt: ?*sqlite3_stmt, column: c_int) c_int;
pub extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_reset(stmt: ?*sqlite3_stmt) c_int;
pub extern fn sqlite3_busy_timeout(db: ?*sqlite3, ms: c_int) c_int;
pub extern fn sqlite3_errmsg(db: ?*sqlite3) [*:0]const u8;
pub extern fn sqlite3_wal_checkpoint_v2(db: ?*sqlite3, z_db: ?[*:0]const u8, e_mode: c_int, pn_log: ?*c_int, pn_ckpt: ?*c_int) c_int;
pub extern fn sqlite3_free(ptr: ?*anyopaque) void;
