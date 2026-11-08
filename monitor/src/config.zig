//! cc-ran の config.json（spec §5.1）。I/O を持たない純粋な関数だけを置く。

const std = @import("std");

/// config.json を読んだ結果。すべての項目は任意で、ない項目は既定値（spec §9）になる。
/// models の上書きを持つフィールドは、実装者が追加する。
pub const Config = struct {
    /// thresholds.warn
    warn: f64 = 0.70,
    /// thresholds.critical
    critical: f64 = 0.90,
    /// endedGraceSeconds をミリ秒にした値
    ended_grace_ms: i64 = 300_000,

    /// config の models にある、そのモデルのウィンドウサイズ。なければ null。
    pub fn modelOverride(self: *const Config, id: []const u8) !?u64 {
        _ = self;
        _ = id;
        return error.NotImplemented;
    }
};

/// config.json の中身を読む。読めない JSON は、すべて既定値にする。
pub fn parse(arena: std.mem.Allocator, json: []const u8) !Config {
    _ = arena;
    _ = json;
    return error.NotImplemented;
}
