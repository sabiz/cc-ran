const std = @import("std");

/// テストファイルはここに 1 つずつ登録する（src/ の中には test ブロックを書かない）。
const test_files = [_][]const u8{
    "tests/smoke_test.zig",
    "tests/sqlite_link_test.zig",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sqlite = b.addLibrary(.{
        .linkage = .static,
        .name = "sqlite3",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    sqlite.root_module.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = &.{ "-DSQLITE_DQS=0", "-DSQLITE_THREADSAFE=1", "-DSQLITE_OMIT_LOAD_EXTENSION" },
    });

    const exe = b.addExecutable(.{
        .name = "cc-ran",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addDependencies(b, exe.root_module, sqlite);
    b.installArtifact(exe);

    const test_step = b.step("test", "Run tests");
    for (test_files) |path| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
            }),
        });
        addDependencies(b, tests.root_module, sqlite);
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}

/// 実行ファイルとテストに共通の依存を与える。
fn addDependencies(b: *std.Build, module: *std.Build.Module, sqlite: *std.Build.Step.Compile) void {
    module.link_libc = true;
    module.linkLibrary(sqlite);
    module.addAnonymousImport("sqlite_c", .{ .root_source_file = b.path("src/store/sqlite_c.zig") });
    module.addAnonymousImport("init_sql", .{ .root_source_file = b.path("../contracts/schema/001_init.sql") });
}
