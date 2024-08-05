const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    // create shim only target for building
    const shim_target = b.step("nexpod-host-shim", "Only the host shim");
    const shim = b.addExecutable(.{
        .name = "nexpod-host-shim",
        .root_source_file = b.path("src/shim.zig"),
        .target = target,
        .optimize = optimize,
    });
    shim_target.dependOn(&b.addInstallArtifact(shim, .{
        .dest_dir = .{
            .override = .{
                .custom = "libexec/zig/",
            },
        },
    }).step);
    b.getInstallStep().dependOn(shim_target);

    // create lib only target for building
    const lib_target = b.step("nexpod-library", "Only the library");
    const lib = b.addStaticLibrary(.{
        .name = "nexpod",
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_target.dependOn(&b.addInstallArtifact(lib, .{}).step);
    b.getInstallStep().dependOn(lib_target);

    // tests
    const test_step = b.step("test", "Run unit tests");

    // for lib
    const lib_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    test_step.dependOn(&run_lib_unit_tests.step);

    // for shim
    const shim_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/shim.zig"),
        .target = target,
        .optimize = optimize,
    });
    const run_shim_unit_tests = b.addRunArtifact(shim_unit_tests);
    test_step.dependOn(&run_shim_unit_tests.step);
}
