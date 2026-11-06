//! cc-ran のプロダクトコードの入口。main.zig とテストはここから import する。

pub const model = @import("model.zig");
pub const sqlite_c = @import("sqlite_c");

/// contracts/schema/001_init.sql
pub const init_sql: [:0]const u8 = @embedFile("init_sql");
/// contracts/models.json
pub const models_json: [:0]const u8 = @embedFile("models_json");
