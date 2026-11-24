//! cc-ran の config.json（spec §5.1）。I/O を持たない純粋な関数だけを置く。

const std = @import("std");

/// config.json を読んだ結果。すべての項目は任意で、ない項目は既定値（spec §9）になる。
pub const Config = struct {
    /// thresholds.warn
    warn: f64 = 0.70,
    /// thresholds.critical
    critical: f64 = 0.90,
    /// endedGraceSeconds をミリ秒にした値
    ended_grace_ms: i64 = 300_000,

    /// models
    models: ?std.json.ArrayHashMap(u64) = null,

    /// config の models にある、そのモデルのウィンドウサイズ。なければ null。
    pub fn modelOverride(self: *const Config, id: []const u8) ?u64 {
        const models = self.models orelse return null;
        return models.map.get(id);
    }
};

const Thresholds = struct {
    warn: ?f64 = null,
    critical: ?f64 = null,
};

const ConfigJson = struct {
    thresholds: ?Thresholds = null,
    models: ?std.json.ArrayHashMap(u64) = null,
    endedGraceSeconds: ?i64 = null,
};

/// config.json の中身を読む。読めない JSON は、すべて既定値にする。
pub fn parse(arena: std.mem.Allocator, json: []const u8) !Config {
    var config: Config = .{};
    const parsed_json = std.json.parseFromSliceLeaky(ConfigJson, arena, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return config;
    if (parsed_json.thresholds) |thresholds| {
        if (thresholds.warn) |warn| {
            config.warn = warn;
        }
        if (thresholds.critical) |critical| {
            config.critical = critical;
        }
    }
    if (parsed_json.endedGraceSeconds) |ended_grace_seconds| {
        config.ended_grace_ms = ended_grace_seconds * 1_000;
    }
    config.models = parsed_json.models;
    return config;
}
