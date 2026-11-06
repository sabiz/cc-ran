// spike：Task 11 で削除する。プロダクトコードではない。
// 確かめること：プラグインの hook から PATH 上の cc-ran を呼べるか、Hook 入力の実際のキー、
// 切り離して起動した子プロセスが Claude Code の終了後も生き残るか。
// ログに書くのはキー名と列挙値だけ。本文の値は書かない。
const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

const Io = std.Io;

fn log(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
    const file = Io.Dir.createFileAbsolute(io, options.log_path, .{ .truncate = false }) catch return;
    defer file.close(io);
    const end = file.length(io) catch return;
    file.writePositionalAll(io, line, end) catch return;
}

fn nowMs(io: Io) i64 {
    return Io.Clock.real.now(io).toMilliseconds();
}

const win = struct {
    const StartupInfoW = extern struct {
        cb: u32 = @sizeOf(StartupInfoW),
        reserved: ?[*:0]u16 = null,
        desktop: ?[*:0]u16 = null,
        title: ?[*:0]u16 = null,
        x: u32 = 0,
        y: u32 = 0,
        x_size: u32 = 0,
        y_size: u32 = 0,
        x_count_chars: u32 = 0,
        y_count_chars: u32 = 0,
        fill: u32 = 0,
        flags: u32 = 0,
        show_window: u16 = 0,
        reserved2_size: u16 = 0,
        reserved2: ?*u8 = null,
        std_input: ?*anyopaque = null,
        std_output: ?*anyopaque = null,
        std_error: ?*anyopaque = null,
    };
    const ProcessInformation = extern struct {
        process: ?*anyopaque = null,
        thread: ?*anyopaque = null,
        process_id: u32 = 0,
        thread_id: u32 = 0,
    };
    extern "kernel32" fn CreateProcessW(app: ?[*:0]const u16, cmd: ?[*:0]u16, pa: ?*anyopaque, ta: ?*anyopaque, inherit: i32, flags: u32, env: ?*anyopaque, dir: ?[*:0]const u16, si: *StartupInfoW, pi: *ProcessInformation) callconv(.winapi) i32;
    extern "kernel32" fn GetModuleFileNameW(module: ?*anyopaque, buf: [*]u16, n: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
    extern "kernel32" fn CloseHandle(handle: ?*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn IsProcessInJob(process: ?*anyopaque, job: ?*anyopaque, result: *i32) callconv(.winapi) i32;
    extern "kernel32" fn QueryInformationJobObject(job: ?*anyopaque, class: i32, info: *anyopaque, len: u32, ret: ?*u32) callconv(.winapi) i32;

    const DETACHED_PROCESS: u32 = 0x00000008;
    const CREATE_NEW_PROCESS_GROUP: u32 = 0x00000200;
    const CREATE_NO_WINDOW: u32 = 0x08000000;
    const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x01000000;

    fn logJob(io: Io) void {
        var in_job: i32 = 0;
        _ = IsProcessInJob(GetCurrentProcess(), null, &in_job);
        var info: [64]u8 align(8) = undefined;
        var limit_flags: u32 = 0;
        if (QueryInformationJobObject(null, 2, &info, info.len, null) != 0) {
            limit_flags = std.mem.readInt(u32, info[16..20], .little);
        }
        log(io, "job in_job={d} limit_flags=0x{x} breakaway_ok={} silent_breakaway_ok={} kill_on_close={}", .{
            in_job,
            limit_flags,
            limit_flags & 0x800 != 0,
            limit_flags & 0x1000 != 0,
            limit_flags & 0x2000 != 0,
        });
    }

    fn spawnChild(io: Io, breakaway: bool) void {
        var exe: [1024]u16 = undefined;
        const len = GetModuleFileNameW(null, &exe, exe.len - 1);
        exe[len] = 0;
        const suffix = std.unicode.utf8ToUtf16LeStringLiteral(" child");
        var cmd: [1100]u16 = undefined;
        cmd[0] = '"';
        @memcpy(cmd[1 .. 1 + len], exe[0..len]);
        cmd[1 + len] = '"';
        @memcpy(cmd[2 + len .. 2 + len + suffix.len], suffix);
        cmd[2 + len + suffix.len] = 0;

        var flags = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW;
        if (breakaway) flags |= CREATE_BREAKAWAY_FROM_JOB;
        var si: StartupInfoW = .{};
        var pi: ProcessInformation = .{};
        // ハンドルを継承しない（Hook の stdout のパイプを子プロセスが掴み続けないようにする）
        const ok = CreateProcessW(@ptrCast(&exe), @ptrCast(&cmd), null, null, 0, flags, null, null, &si, &pi);
        if (ok == 0) {
            log(io, "spawn FAILED breakaway={} last_error={d}", .{ breakaway, GetLastError() });
            return;
        }
        log(io, "spawn ok breakaway={} child_pid={d}", .{ breakaway, pi.process_id });
        _ = CloseHandle(pi.thread);
        _ = CloseHandle(pi.process);
    }
};

const posix = struct {
    extern "c" fn fork() c_int;
    extern "c" fn setsid() c_int;
    extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern "c" fn dup2(old: c_int, new: c_int) c_int;
    extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
    extern "c" fn _exit(code: c_int) noreturn;

    fn spawnChild(io: Io, self: [*:0]const u8) void {
        const pid = fork();
        if (pid < 0) {
            log(io, "spawn FAILED fork", .{});
            return;
        }
        if (pid > 0) {
            log(io, "spawn ok first_fork_pid={d}", .{pid});
            return;
        }
        // 子プロセス：新しいセッションを作り、Hook のパイプを手放してから自分を起動し直す
        _ = setsid();
        const null_fd = open("/dev/null", 2);
        _ = dup2(null_fd, 0);
        _ = dup2(null_fd, 1);
        _ = dup2(null_fd, 2);
        const argv = [_:null]?[*:0]const u8{ self, "child" };
        _ = execvp(self, &argv);
        _exit(127);
    }
};

fn runHook(init: std.process.Init, self: [*:0]const u8) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const start = nowMs(io);

    var buf: [4096]u8 = undefined;
    var reader = Io.File.stdin().reader(io, &buf);
    const input = try reader.interface.allocRemaining(arena, .unlimited);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, input, .{});
    const root = parsed.value.object;

    var keys: std.ArrayList(u8) = .empty;
    var it = root.iterator();
    while (it.next()) |entry| {
        try keys.appendSlice(arena, entry.key_ptr.*);
        try keys.append(arena, ' ');
    }

    const str = struct {
        fn get(obj: std.json.ObjectMap, key: []const u8) []const u8 {
            const value = obj.get(key) orelse return "-";
            return switch (value) {
                .string => |s| s,
                else => "?",
            };
        }
    }.get;

    const event = str(root, "hook_event_name");
    log(io, "hook t={d} event={s} source={s} notification={s} model={s} tool={s} agent={s} disable_1m={} keys=[{s}]", .{
        start,
        event,
        str(root, "source"),
        str(root, "notification_type"),
        str(root, "model"),
        str(root, "tool_name"),
        if (root.get("agent_id") == null) "-" else "yes",
        init.environ_map.contains("CLAUDE_CODE_DISABLE_1M_CONTEXT"),
        keys.items,
    });

    if (std.mem.eql(u8, event, "SessionStart")) {
        if (builtin.os.tag == .windows) {
            win.logJob(io);
            win.spawnChild(io, init.environ_map.contains("PROBE_BREAKAWAY"));
        } else {
            posix.spawnChild(io, self);
        }
    }
    log(io, "hook done event={s} ms={d}", .{ event, nowMs(io) - start });
}

fn runChild(init: std.process.Init) void {
    const io = init.io;
    var i: u32 = 0;
    while (i < 60) : (i += 1) {
        log(io, "child heartbeat n={d} t={d}", .{ i, nowMs(io) });
        io.sleep(.fromSeconds(1), .real) catch return;
    }
}

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 0;
    if (args.len < 2) return 0;
    if (std.mem.eql(u8, args[1], "child")) {
        runChild(init);
    } else {
        runHook(init, args[0].ptr) catch |err| log(init.io, "hook error {s}", .{@errorName(err)});
    }
    return 0;
}
