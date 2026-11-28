//! transcript（.jsonl）の末尾から、最後の assistant 行のモデルと使用量を読む（spec §4.1）。
//! 読む項目は type、isSidechain、message.model、message.usage だけ。本文は読まない。

const std = @import("std");

pub const Usage = struct {
    model: []const u8,
    /// input_tokens + cache_creation_input_tokens + cache_read_input_tokens（output_tokens は足さない）
    used: u64,
};

/// 末尾の読み取り範囲の初期値と上限（spec §9）
pub const initial_tail_bytes: usize = 256 * 1024;
pub const max_tail_bytes: usize = 4 * 1024 * 1024;

/// transcript の 1 行の受け皿。spec §2.1 で読んでよいキー（type、isSidechain、message.model、message.usage）だけを書く。
/// ここに書いていないキー（message.content などの本文）は読まずに捨てる。本文を表すキーを足してはいけない。
const TranscriptLine = struct {
    type: ?[]const u8 = null,
    isSidechain: ?bool = null,
    message: ?Message = null,
};

const Message = struct {
    model: ?[]const u8 = null,
    usage: ?UsageJson = null,
};

const UsageJson = struct {
    input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
};

/// tail の中で条件に合う最後の assistant 行を探す。なければ null。
/// - 対象外：`isSidechain` が true の行、`message.model` が `<synthetic>` の行。
/// - JSON として読めない行（途中から始まる先頭行、途中で切れた行）は無視する。
pub fn extractUsage(arena: std.mem.Allocator, tail: []const u8) !?Usage {
    var lines = std.mem.splitBackwardsScalar(u8, tail, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) {
            continue;
        }
        const transcript = std.json.parseFromSliceLeaky(TranscriptLine, arena, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        const transcript_type = transcript.type orelse continue;
        if (std.mem.eql(u8, transcript_type, "assistant") and transcript.isSidechain != true) {
            const message = transcript.message orelse continue;
            const model = message.model orelse continue;
            const usage = message.usage orelse continue;
            if (!std.mem.eql(u8, model, "<synthetic>")) {
                return .{
                    .model = model,
                    .used = usage.input_tokens +| usage.cache_creation_input_tokens +| usage.cache_read_input_tokens,
                };
            }
        }
    }
    return null;
}

/// path の末尾を initial_tail_bytes から倍々に広げて読み、max_tail_bytes まで探す。
/// ファイルがなければ null。返した model は gpa で確保したもので、呼び出し側が解放する。
pub fn readUsage(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !?Usage {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const stat = try file.stat(io);
    const file_size = stat.size;
    var buff_size = initial_tail_bytes;
    while (true) {
        const size = @min(buff_size, file_size);
        const buff = try gpa.alloc(u8, size);
        defer gpa.free(buff);
        const read_size = try file.readPositionalAll(io, buff, file_size - size);
        // 大きさを調べた後にファイルが短くなると、読めるのは size より少ない。読めた分だけを渡す。
        const usage = try extractUsage(arena, buff[0..read_size]);
        if (usage) |usage_value| {
            return .{
                .used = usage_value.used,
                .model = try gpa.dupe(u8, usage_value.model),
            };
        }
        if (read_size >= file_size) {
            break;
        }
        buff_size *= 2;
        if (buff_size > max_tail_bytes) {
            break;
        }
    }
    return null;
}
