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

    const shim_module = b.createModule(.{
        .root_source_file = b.path("src/shim/shim.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addModule("libnexpod", .{
        .root_source_file = b.path("src/lib/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.addImport("logging", log_module);
    lib.addImport("utils", utils_module);
    lib.addImport("zeit", zeit.module("zeit"));

    const daemon_module = b.createModule(.{
        .root_source_file = b.path("src/daemon/daemon.zig"),
        .target = target,
        .optimize = optimize,
    });
    daemon_module.addImport("clap", clap.module("clap"));
    daemon_module.addImport("logging", log_module);
    daemon_module.addImport("utils", utils_module);

    // create shim only target for building
    const shim_target = b.step("libnexpod-host-shim", "Only the host shim");
    const shim = b.addExecutable(.{
        .name = "libnexpod-host-shim",
        .root_module = shim_module,
    });
    shim_target.dependOn(&b.addInstallArtifact(shim, .{
        .dest_dir = .{
            .override = .{
                .custom = "libexec/libnexpod/",
            },
        },
    }).step);
    b.getInstallStep().dependOn(shim_target);

    // create daemon only target for building
    const daemon_target = b.step("libnexpodd", "Only the daemon");
    const daemon = b.addExecutable(.{
        .name = "libnexpodd",
        .root_module = daemon_module,
    });
    daemon_target.dependOn(&b.addInstallArtifact(daemon, .{
        .dest_dir = .{
            .override = .{
                .custom = "libexec/libnexpod/",
            },
        },
    }).step);
    b.getInstallStep().dependOn(daemon_target);

    // tests
    const test_step = b.step("test", "Run all tests");

    // unit tests
    const unittest_step = b.step("unittests", "Run unit tests");
    test_step.dependOn(unittest_step);
    // base modules
    unittest_step.dependOn(&b.addTest(.{
        .name = "logging",
        .root_module = log_module,
    }).step);
    unittest_step.dependOn(&b.addTest(.{
        .name = "utils",
        .root_module = utils_module,
    }).step);

    // shim
    const shim_unit_tests = b.addTest(.{
        .name = "shim",
        .root_module = shim_module,
    });
    const shim_unit_tests_run = b.addRunArtifact(shim_unit_tests);
    const shim_unit_test_step = b.step("shimunittests", "Run only the unit tests of the shim");
    shim_unit_test_step.dependOn(&shim_unit_tests_run.step);
    unittest_step.dependOn(shim_unit_test_step);

    // for lib
    const lib_unit_tests = b.addTest(.{
        .name = "lib",
        .root_module = lib,
    });
    lib_unit_tests.linkLibC();
    const lib_unit_tests_run = b.addRunArtifact(lib_unit_tests);
    const lib_unit_test_step = b.step("libunittests", "Run only the unit tests for the library");
    lib_unit_test_step.dependOn(&lib_unit_tests_run.step);
    unittest_step.dependOn(lib_unit_test_step);

    // for daemon
    const daemon_unit_tests = b.addTest(.{
        .name = "daemon",
        .root_module = daemon_module,
    });
    const daemon_unit_tests_run = b.addRunArtifact(daemon_unit_tests);
    const daemon_unit_test_step = b.step("daemonunittests", "Run only the unit tests of the daemon");
    daemon_unit_test_step.dependOn(&daemon_unit_tests_run.step);
    unittest_step.dependOn(daemon_unit_test_step);

    // system tests
    const systemtest_step = b.step("systemtests", "Run system tests");
    test_step.dependOn(systemtest_step);

    const optionModule = b.addOptions();
    optionModule.addOption(u32, "logLevel", b.option(u32, "log-level", "used log level for system tests") orelse 0);

    try addSystemTests(b, .{
        .root_case = systemtest_step,
        .dir_path = "tests",
        .modules = &[_]Module{ .{
            .name = "libnexpod",
            .module = lib,
        }, .{
            .name = "options",
            .module = optionModule.createModule(),
        } },
        .daemon = daemon,
    });

    const docs = b.step("docs", "generate documentation");
    {
        const lib_doc_helper = b.addObject(.{
            .name = "lib",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/lib/lib.zig"),
                .target = target,
                .optimize = optimize,
            }),
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
    daemon: *std.Build.Step.Compile,
}) !void {
    const setup_check_build = b.addExecutable(.{
        .name = "setup_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/list-images.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    addModules(setup_check_build.root_module, args.modules);
    const setup_check = b.addRunArtifact(setup_check_build);

    var dir = try b.build_root.handle.openDir(args.dir_path, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        const lastDotIndex = std.mem.lastIndexOfScalar(u8, entry.name, '.') orelse continue;
        if (lastDotIndex == 0) continue;
        if (!std.mem.eql(u8, ".zig", entry.name[lastDotIndex..])) {
            continue;
        }
        const path = try std.mem.concat(b.allocator, u8, &[_][]const u8{ args.dir_path, "/", entry.name });
        const name = try std.mem.concat(b.allocator, u8, &[_][]const u8{ "system-test-", entry.name[0..lastDotIndex] });
        const test_case = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .optimize = .Debug,
                .target = b.graph.host,
            }),
        });
        args.root_case.dependOn(&b.addInstallArtifact(test_case, .{
            .dest_dir = .{
                .override = .{
                    .custom = "system-tests",
                },
            },
        }).step);
        addModules(test_case.root_module, args.modules);

        test_case.step.dependOn(&setup_check.step);

        var run_test_case = b.addRunArtifact(test_case);
        run_test_case.addFileArg(args.daemon.getEmittedBin());
        args.root_case.dependOn(&run_test_case.step);
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
