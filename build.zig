const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });
    const zeit = b.dependency("zeit", .{
        .target = target,
        .optimize = optimize,
    });

    const log_module = b.addModule("logging", .{
        .root_source_file = b.path("src/utils/logging.zig"),
        .target = target,
        .optimize = optimize,
    });
    const utils_module = b.addModule("utils", .{
        .root_source_file = b.path("src/utils/utils.zig"),
        .target = target,
        .optimize = optimize,
    });

    // create shim only target for building
    const shim_target = b.step("nexpod-host-shim", "Only the host shim");
    const shim = b.addExecutable(.{
        .name = "nexpod-host-shim",
        .root_source_file = b.path("src/shim/shim.zig"),
        .target = target,
        .optimize = optimize,
    });
    shim_target.dependOn(&b.addInstallArtifact(shim, .{
        .dest_dir = .{
            .override = .{
                .custom = "libexec/nexpod/",
            },
        },
    }).step);
    b.getInstallStep().dependOn(shim_target);

    // create lib only target for building
    const lib = b.addModule("libnexpod", .{
        .root_source_file = b.path("src/lib/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib_modules = [_]Module{
        .{
            .name = "logging",
            .module = log_module,
        },
        .{
            .name = "utils",
            .module = utils_module,
        },
        .{
            .name = "zeit",
            .module = zeit.module("zeit"),
        },
    };
    addModules(lib, &lib_modules);

    // create daemon only target for building
    const daemon_target = b.step("nexpodd", "Only the daemon");
    const daemon = b.addExecutable(.{
        .name = "nexpodd",
        .root_source_file = b.path("src/daemon/daemon.zig"),
        .target = target,
        .optimize = optimize,
    });
    const daemon_modules = [_]Module{
        .{
            .name = "clap",
            .module = clap.module("clap"),
        },
        .{
            .name = "logging",
            .module = log_module,
        },
        .{
            .name = "utils",
            .module = utils_module,
        },
    };
    addModules(&daemon.root_module, &daemon_modules);
    daemon_target.dependOn(&b.addInstallArtifact(daemon, .{
        .dest_dir = .{
            .override = .{
                .custom = "libexec/nexpod/",
            },
        },
    }).step);
    b.getInstallStep().dependOn(daemon_target);

    // tests
    const test_step = b.step("test", "Run all tests");

    // unit tests
    const unittest_step = b.step("unittests", "Run unit tests");
    test_step.dependOn(unittest_step);

    // for the utils
    try addTestCases(b, test_step, "src/utils", &[_]Module{}, &target, &optimize, true);

    // for lib
    const lib_unit_tests = b.step("libunittests", "Run only the unit tests for the library");
    try addTestCases(b, lib_unit_tests, "src/lib", &lib_modules, &target, &optimize, true);
    test_step.dependOn(lib_unit_tests);

    // for shim
    const shim_unit_tests = b.step("shimunittests", "Run only the unit tests of the shim");
    try addTestCases(b, shim_unit_tests, "src/shim", &[_]Module{}, &target, &optimize, false);
    test_step.dependOn(shim_unit_tests);

    // for daemon
    const daemon_unit_tests = b.step("daemonunittests", "Run only the unit tests of the daemon");
    try addTestCases(b, daemon_unit_tests, "src/daemon", &daemon_modules, &target, &optimize, false);
    test_step.dependOn(daemon_unit_tests);

    // system tests
    const systemtest_step = b.step("systemtests", "Run system tests");
    test_step.dependOn(systemtest_step);
    try addSystemTests(b, .{
        .root_case = systemtest_step,
        .dir_path = "tests",
        .modules = &[_]Module{.{
            .name = "libnexpod",
            .module = lib,
        }},
        .target = &target,
        .optimize = &optimize,
        .libc = false,
        .daemon = daemon,
    });

    const docs = b.step("docs", "generate documentation");
    {
        const lib_doc_helper = b.addObject(.{
            .name = "lib",
            .root_source_file = b.path("src/lib/lib.zig"),
            .target = target,
            .optimize = optimize,
        });
        const lib_docs = lib_doc_helper.getEmittedDocs();
        docs.dependOn(&b.addInstallDirectory(.{
            .source_dir = lib_docs,
            .install_dir = .prefix,
            .install_subdir = "libnexpod/docs",
        }).step);
    }
}

fn addSystemTests(b: *std.Build, args: struct {
    root_case: *std.Build.Step,
    dir_path: []const u8,
    modules: []const Module,
    target: *const std.Build.ResolvedTarget,
    optimize: *const std.builtin.OptimizeMode,
    libc: bool,
    daemon: *std.Build.Step.Compile,
}) !void {
    const setup_step = b.addSystemCommand(&[_][]const u8{
        "tests/setup.sh",
    });

    var dir = try b.build_root.handle.openDir(args.dir_path, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (!std.mem.eql(u8, ".zig", std.fs.path.extension(entry.name))) {
            continue;
        }
        const path = try std.mem.concat(b.allocator, u8, &[_][]const u8{ args.dir_path, "/", entry.name });
        const test_case = b.addExecutable(.{
            .name = entry.name,
            .root_source_file = b.path(path),
            .optimize = args.optimize.*,
            .target = args.target.*,
        });
        if (args.libc) {
            test_case.linkLibC();
        }
        addModules(&test_case.root_module, args.modules);

        test_case.step.dependOn(&setup_step.step);

        var run_test_case = b.addRunArtifact(test_case);
        run_test_case.addFileArg(args.daemon.getEmittedBin());
        args.root_case.dependOn(&run_test_case.step);
    }
}

fn addTestCases(b: *std.Build, root_case: *std.Build.Step, dir_path: []const u8, modules: []const Module, target: *const std.Build.ResolvedTarget, optimize: *const std.builtin.OptimizeMode, libc: bool) !void {
    var dir = try b.build_root.handle.openDir(dir_path, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (!std.mem.eql(u8, ".zig", std.fs.path.extension(entry.name))) {
            continue;
        }
        const path = try std.mem.concat(b.allocator, u8, &[_][]const u8{ dir_path, "/", entry.name });
        const test_case = b.addTest(.{
            .root_source_file = b.path(path),
            .target = target.*,
            .optimize = optimize.*,
        });
        if (libc) {
            test_case.linkLibC();
        }
        addModules(&test_case.root_module, modules);
        const run_test_case = b.addRunArtifact(test_case);
        root_case.dependOn(&run_test_case.step);
    }
}

const Module = struct {
    name: []const u8,
    module: *std.Build.Module,
};
fn addModules(node: *std.Build.Module, modules: []const Module) void {
    for (modules) |mod| {
        node.addImport(mod.name, mod.module);
    }
}
