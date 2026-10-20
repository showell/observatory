const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // webbox is two modules: `webbox`, portable, what the application's code
    // imports; and `webbox_linux`, the Linux host, for a Linux `main` only.
    // `host_io` is the one file its sources take their `Io` from.
    const webbox_dep = b.dependency("webbox", .{ .target = target, .optimize = optimize });
    const webbox = webbox_dep.module("webbox");
    const webbox_linux = webbox_dep.module("webbox_linux");
    const host_io = webbox_dep.module("host_io");

    // **ON LINUX**: zig build run (serves its page on :9104).
    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "webbox", .module = webbox },
            .{ .name = "host_io", .module = host_io },
            .{ .name = "webbox_linux", .module = webbox_linux },
        },
    });
    const exe = b.addExecutable(.{ .name = "observatory", .root_module = main_mod });
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run the Observatory on Linux (its page on localhost:9104)").dependOn(&run.step);

    // **THE TESTS**: the app's (its schedule, its conf, its lines, /version
    // read) and the poll on Linux against servers on 127.0.0.1
    // (src/linux_test.zig), which needs webbox's Linux half.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "webbox", .module = webbox },
            .{ .name = "host_io", .module = host_io },
            .{ .name = "webbox_linux", .module = webbox_linux },
        },
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    b.step("test", "The app's tests, and the poll on Linux against local servers").dependOn(&b.addRunArtifact(tests).step);

    // **ON METAL**: zig-metal-unikernel's kernel, a sibling checkout, hosting
    // hosted.zig's `site`: zig-out/bin/observatory.elf. The module names no
    // target or optimize mode and imports neither webbox nor host_io: the
    // kernel supplies its own.
    const metal_step = b.step("metal", "Build the Observatory as a zig-metal-unikernel kernel, zig-out/bin/observatory.elf (ReleaseSafe; ../zig-metal-unikernel)");
    if (b.lazyDependency("zig_metal_unikernel", .{})) |kernel| {
        if (b.lazyImport(@This(), "zig_metal_unikernel")) |kernel_build| {
            const elf = kernel_build.addAppKernel(b, kernel, .{
                .name = "observatory.elf",
                .module = b.createModule(.{ .root_source_file = b.path("src/hosted.zig") }),
                .assets = b.path("assets.zon"),
                .optimize = .safe,
            });
            metal_step.dependOn(&b.addInstallArtifact(elf, .{}).step);
        }
    }
}
