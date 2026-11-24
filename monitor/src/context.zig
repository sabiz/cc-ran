//! コンテキストウィンドウの決定と段階分け（spec §4）。I/O を持たない純粋な関数だけを置く。

const std = @import("std");
const model = @import("model.zig");
const config = @import("config.zig");

const ContextLevel = model.ContextLevel;
const WindowSource = model.WindowSource;
const Config = config.Config;

/// models.json の models 配列の 1 行。
const ModelEntry = struct {
    id: []const u8,
    window: u64,
};

/// contracts/models.json を読んだ結果。フィールド名は JSON のキーと一致させ、そのまま読む。
pub const ModelTable = struct {
    /// 表にないモデルに仮定するウィンドウサイズ（default_window）
    default_window: u64,
    /// 使用量が表の値を超えたときに引き上げる先（one_million）
    one_million: u64,
    /// 組み込みのモデル表。lookup で id の完全一致で引く。
    models: []const ModelEntry,

    pub fn parse(arena: std.mem.Allocator, json: []const u8) !ModelTable {
        return std.json.parseFromSliceLeaky(ModelTable, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
    }

    /// id と完全に一致するモデルのウィンドウサイズ。なければ null。
    pub fn lookup(self: ModelTable, id: []const u8) ?u64 {
        for (self.models) |m| {
            if (std.mem.eql(u8, m.id, id)) {
                return m.window;
            }
        }
        return null;
    }
};

pub const Window = struct {
    tokens: ?u64,
    source: WindowSource,
};

/// 末尾の -YYYYMMDD（ハイフンと 8 桁の数字）だけを外す。それ以外はそのまま返す。
pub fn stripDateSuffix(id: []const u8) []const u8 {
    if (id.len < 9 or id[id.len - 9] != '-' or std.mem.findNone(u8, id[id.len - 8 ..], "0123456789") != null) {
        return id;
    }
    return id[0 .. id.len - 9];
}

/// spec §4.2 の優先順でウィンドウサイズを決める。
pub fn resolveWindow(table: ModelTable, overrides: *const Config, model_id: ?[]const u8, used: ?u64, disable_1m: bool) Window {
    if (model_id == null and used == null) {
        return .{
            .tokens = null,
            .source = .unknown,
        };
    }
    var window_size: ?u64 = null;
    if (model_id) |raw_model_id| {
        const model_id_without_date = stripDateSuffix(raw_model_id);
        if (overrides.modelOverride(model_id_without_date)) |window_size_overridden| {
            return .{
                .tokens = window_size_overridden,
                .source = .config,
            };
        }
        window_size = table.lookup(model_id_without_date);
    }
    var result: Window = if (window_size) |tokens| .{
        .tokens = tokens,
        .source = .builtin,
    } else .{
        .tokens = table.default_window,
        .source = .fallback,
    };
    if (disable_1m) {
        result.tokens = @min(table.default_window, result.tokens.?);
        return result;
    }
    if (result.tokens.? < (used orelse 0)) {
        result = .{
            .tokens = table.one_million,
            .source = .observed,
        };
    }
    return result;
}

/// spec §4.4 の段階分け。しきい値は settings の warn と critical を使う。
pub fn level(used: ?u64, window: ?u64, settings: *const Config) ContextLevel {
    const used_float: f64 = @floatFromInt(used orelse return .unknown);
    const window_float: f64 = @floatFromInt(window orelse return .unknown);
    if (window_float == 0) {
        return .unknown;
    }
    const rate: f64 = used_float / window_float;
    if (rate >= settings.critical) {
        return .critical;
    } else if (rate >= settings.warn) {
        return .warn;
    }
    return .ok;
}
