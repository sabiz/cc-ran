//! コンテキストウィンドウの決定と段階分け（spec §4）。I/O を持たない純粋な関数だけを置く。

const std = @import("std");
const model = @import("model.zig");
const config = @import("config.zig");

const ContextLevel = model.ContextLevel;
const WindowSource = model.WindowSource;
const Config = config.Config;

/// contracts/models.json を読んだ結果。モデルの一覧の持ち方は、実装者が決める。
pub const ModelTable = struct {
    /// 表にないモデルに仮定するウィンドウサイズ（default_window）
    default_window: u64,
    /// 使用量が表の値を超えたときに引き上げる先（one_million）
    one_million: u64,

    pub fn parse(arena: std.mem.Allocator, json: []const u8) !ModelTable {
        _ = arena;
        _ = json;
        return error.NotImplemented;
    }

    /// id と完全に一致するモデルのウィンドウサイズ。なければ null。
    pub fn lookup(self: ModelTable, id: []const u8) !?u64 {
        _ = self;
        _ = id;
        return error.NotImplemented;
    }
};

pub const Window = struct {
    tokens: ?u64,
    source: WindowSource,
};

/// 末尾の -YYYYMMDD（ハイフンと 8 桁の数字）だけを外す。それ以外はそのまま返す。
pub fn stripDateSuffix(id: []const u8) ![]const u8 {
    _ = id;
    return error.NotImplemented;
}

/// spec §4.2 の優先順でウィンドウサイズを決める。
pub fn resolveWindow(table: ModelTable, overrides: *const Config, model_id: ?[]const u8, used: ?u64, disable_1m: bool) !Window {
    _ = table;
    _ = overrides;
    _ = model_id;
    _ = used;
    _ = disable_1m;
    return error.NotImplemented;
}

/// spec §4.4 の段階分け。しきい値は settings の warn と critical を使う。
pub fn level(used: ?u64, window: ?u64, settings: *const Config) !ContextLevel {
    _ = used;
    _ = window;
    _ = settings;
    return error.NotImplemented;
}
