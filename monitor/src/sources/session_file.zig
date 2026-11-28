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

/// セッションファイルの受け皿。フィールド名はファイルのキー名（camelCase）に合わせる。
/// どのキーもないことがあるので、すべて null 許容にする。
const SessionFileJson = struct {
    sessionId: ?[]const u8 = null,
    pid: ?i64 = null,
    procStart: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    name: ?[]const u8 = null,
    kind: ?[]const u8 = null,
    status: ?[]const u8 = null,
    statusUpdatedAt: ?i64 = null,
};

/// 1 つのファイルの中身を読む。壊れている、または sessionId か pid がなければ null。
pub fn parse(arena: std.mem.Allocator, json: []const u8) !?SessionFile {
    const parsed_json = std.json.parseFromSliceLeaky(SessionFileJson, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    return .{
        .session_id = parsed_json.sessionId orelse return null,
        .pid = parsed_json.pid orelse return null,
        .proc_start = parsed_json.procStart,
        .cwd = parsed_json.cwd,
        .name = parsed_json.name,
        .kind = if (parsed_json.kind) |kind| std.meta.stringToEnum(Kind, kind) orelse .unknown else .unknown,
        .status = if (parsed_json.status) |status| std.meta.stringToEnum(FileStatus, status) orelse .unknown else .unknown,
        .status_updated_at = parsed_json.statusUpdatedAt,
    };
}

/// scanDir が 1 つのセッションファイルから読む上限。実際のファイルは 1 KiB 程度なので、超えたものは壊れているとみなして飛ばす。
const max_file_bytes: usize = 1024 * 1024;

/// dir_path の中の `*.json` だけを読む。`*.key` は開かない。読めないファイルは飛ばす。
/// ディレクトリがなければ空のスライスを返す。順序は決めない。
pub fn scanDir(io: std.Io, arena: std.mem.Allocator, dir_path: []const u8) ![]SessionFile {
    const dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);
    var dir_iter = dir.iterate();
    var results: std.ArrayList(SessionFile) = .empty;
    while (try dir_iter.next(io)) |dir_item| {
        if (dir_item.kind != .file) {
            continue;
        }
        if (!std.mem.endsWith(u8, dir_item.name, ".json")) {
            continue;
        }
        const file = dir.readFileAlloc(io, dir_item.name, arena, .limited(max_file_bytes)) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        const parse_result = try parse(arena, file) orelse continue;
        try results.append(arena, parse_result);
    }
    return results.toOwnedSlice(arena);
}

/// 一覧に出す名前。name → cwd の末尾のディレクトリ名 → session_id の先頭 8 文字の順に選ぶ。
/// cwd の区切りは `/` と `\` の両方を扱う（Windows のパスを macOS で処理しても同じ結果にする）。
/// 空の name は「ない」とみなす。末尾の区切りを外すと何も残らない cwd（`/` など）は session_id にする。
/// 引数の一部をそのまま返し、メモリは確保しない。
pub fn displayName(name: ?[]const u8, cwd: ?[]const u8, session_id: []const u8) []const u8 {
    if (name) |display_name| {
        if (display_name.len > 0) {
            return display_name;
        }
    }
    if (cwd) |cwd_path| {
        var segments = std.mem.splitBackwardsAny(u8, std.mem.trimEnd(u8, cwd_path, "\\/"), "\\/");
        const basename = segments.first();
        if (basename.len > 0) {
            return basename;
        }
    }
    return session_id[0..@min(8, session_id.len)];
}
