const std = @import("std");

/// テストファイルはここに 1 つずつ登録する（src/ の中には test ブロックを書かない）。
const test_files = [_][]const u8{
    "tests/smoke_test.zig",
    "tests/sqlite_link_test.zig",
    "tests/model_test.zig",
    "tests/reducer_test.zig",
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

    // プロダクトコードの本体。main.zig とすべてのテストが import する。
    const cc_ran = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    cc_ran.linkLibrary(sqlite);
    cc_ran.addAnonymousImport("sqlite_c", .{ .root_source_file = b.path("src/store/sqlite_c.zig") });
    cc_ran.addAnonymousImport("init_sql", .{ .root_source_file = b.path("../contracts/schema/001_init.sql") });
    cc_ran.addAnonymousImport("models_json", .{ .root_source_file = b.path("../contracts/models.json") });

    const exe = b.addExecutable(.{
        .name = "cc-ran",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "cc_ran", .module = cc_ran }},
        }),
    });
    b.installArtifact(exe);

    // テストだけが使う値。CLI のテストは、ビルドした実物の cc-ran を実行する。
    const test_options = b.addOptions();
    test_options.addOptionPathDirectory("contracts_dir", b.path("../contracts"));
    test_options.addOptionPath("cc_ran_exe", exe.getEmittedBin());

    const test_step = b.step("test", "Run tests");
    for (test_files) |path| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{.{ .name = "cc_ran", .module = cc_ran }},
            }),
        });
        tests.root_module.addOptions("test_options", test_options);
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}
