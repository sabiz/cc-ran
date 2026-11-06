//! テストの共通処理。

const std = @import("std");
const test_options = @import("test_options");

const max_fixture_bytes = 64 * 1024 * 1024;

/// contracts/ の下のファイルを読む。呼び出し側が解放する。
pub fn readContract(gpa: std.mem.Allocator, sub_path: []const u8) ![]u8 {
    const path = try std.fs.path.join(gpa, &.{ test_options.contracts_dir, sub_path });
    defer gpa.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(max_fixture_bytes));
}
