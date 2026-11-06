// spike：Task 11 で削除する。プロダクトコードではない。
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const log_path = b.option([]const u8, "log", "Absolute path of the probe log") orelse "/tmp/hookprobe.log";

    const options = b.addOptions();
    options.addOption([]const u8, "log_path", log_path);

    const exe = b.addExecutable(.{
        .name = "cc-ran",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.addOptions("options", options);
    b.installArtifact(exe);
}
