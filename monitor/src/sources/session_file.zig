//! `~/.claude/sessions/<pid>.json`（非公開の内部ファイル、spec §2）の adapter。
//! 形式が変わる前提で、知らない項目や欠けた項目があっても止まらないようにする。

const std = @import("std");
const model = @import("../model.zig");

const Kind = model.Kind;
const FileStatus = model.FileStatus;

pub const SessionFile = struct {
    /// sessionId
    session_id: []const u8,
    /// pid
    pid: i64,
    /// procStart。プラットフォームごとに形式が違う不透明な文字列
    proc_start: ?[]const u8,
    /// cwd
    cwd: ?[]const u8,
    /// name
    name: ?[]const u8,
    /// kind。ない値や知らない値は unknown
    kind: Kind,
    /// status。ない値や知らない値は unknown
    status: FileStatus,
    /// statusUpdatedAt（epoch ミリ秒）
    status_updated_at: ?i64,
};

/// 1 つのファイルの中身を読む。壊れている、または sessionId か pid がなければ null。
pub fn parse(arena: std.mem.Allocator, json: []const u8) !?SessionFile {
    _ = arena;
    _ = json;
    return error.NotImplemented;
}

/// dir_path の中の `*.json` だけを読む。`*.key` は開かない。読めないファイルは飛ばす。
/// ディレクトリがなければ空のスライスを返す。順序は決めない。
pub fn scanDir(io: std.Io, arena: std.mem.Allocator, dir_path: []const u8) ![]SessionFile {
    _ = io;
    _ = arena;
    _ = dir_path;
    return error.NotImplemented;
}

/// 一覧に出す名前。name → cwd の末尾のディレクトリ名 → session_id の先頭 8 文字の順に選ぶ。
/// cwd の区切りは `/` と `\` の両方を扱う（Windows のパスを macOS で処理しても同じ結果にする）。
pub fn displayName(name: ?[]const u8, cwd: ?[]const u8, session_id: []const u8) ![]const u8 {
    _ = name;
    _ = cwd;
    _ = session_id;
    return error.NotImplemented;
}
