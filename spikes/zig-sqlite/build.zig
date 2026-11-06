// spike：Task 11 で削除する。プロダクトコードではない。
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zig-sqlite",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("../../monitor/vendor/sqlite/sqlite3.c"),
        .flags = &.{ "-DSQLITE_DQS=0", "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION" },
    });
    exe.root_module.addAnonymousImport("sqlite_c", .{
        .root_source_file = b.path("../../monitor/src/store/sqlite_c.zig"),
    });
    exe.root_module.addAnonymousImport("init_sql", .{
        .root_source_file = b.path("../../contracts/schema/001_init.sql"),
    });
    b.installArtifact(exe);
}
