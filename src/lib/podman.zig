const std = @import("std");
const builtin = @import("builtin");
const log = @import("logging");
const utils = @import("utils");
const errors = @import("errors.zig");
const Mount = @import("container.zig").Mount;
const Image = @import("image.zig").Image;

const label = "com.github.libnexpod";

pub fn getContainerJSON(allocator: std.mem.Allocator, id: []const u8) (std.process.Child.RunError || errors.PodmanErrors)![]const u8 {
    const inspect_argv = [_][]const u8{
        "podman",
        "container",
        "inspect",
        "--format",
        "{{ json . }}",
        id,
    };
    return try call(allocator, &inspect_argv);
}

pub fn getContainerListJSON(allocator: std.mem.Allocator, key: []const u8) (std.process.Child.RunError || errors.PodmanErrors)![]const u8 {
    var get_argv = [_][]const u8{
        "podman",
        "container",
        "list",
        "--all",
        "--format",
        "json",
        "--filter",
        try std.mem.concat(allocator, u8, &[_][]const u8{ "label=" ++ label ++ "=", key }),
    };
    defer allocator.free(get_argv[get_argv.len - 1]);

    return try call(allocator, &get_argv);
}

test "getContainerListJSON leaktest" {
    std.testing.allocator.free(try getContainerListJSON(std.testing.allocator, ""));
}

pub fn getImageJSON(allocator: std.mem.Allocator, id: []const u8) (std.process.Child.RunError || errors.PodmanErrors)![]const u8 {
    const inspect_argv = [_][]const u8{
        "podman",
        "image",
        "inspect",
        "--format",
        "{{ json . }}",
        id,
    };
    return try call(allocator, &inspect_argv);
}

pub fn getImageListJSON(allocator: std.mem.Allocator) (std.process.Child.RunError || errors.PodmanErrors)![]const u8 {
    const get_argv = [_][]const u8{
        "podman",
        "images",
        "--format",
        "json",
        "--filter",
        "label=" ++ label,
    };
    return try call(allocator, &get_argv);
}

test "getImageListJSON leaktest" {
    std.testing.allocator.free(try getImageListJSON(std.testing.allocator));
}

pub fn call(allocator: std.mem.Allocator, argv: []const []const u8) (std.process.Child.RunError || errors.PodmanErrors)![]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            log.err("podman not found\n", .{});
            return errors.PodmanErrors.PodmanNotFound;
        },
        else => |rest| return rest,
    };
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| {
            if (code == 0) {
                return result.stdout;
            } else {
                var argv_str = std.ArrayList(u8).init(allocator);
                defer argv_str.deinit();
                try argv_str.writer().writeByte('[');
                if (argv.len > 0) {
                    for (argv[0 .. argv.len - 1]) |e| {
                        try argv_str.writer().print("{s}, ", .{e});
                    }
                    try argv_str.writer().print("{s}", .{argv[argv.len - 1]});
                }
                try argv_str.writer().writeByte(']');
                const stderr = if (result.stderr.len > 0 and result.stderr[result.stderr.len - 1] == '\n')
                    result.stderr[0 .. result.stderr.len - 1]
                else
                    result.stderr;
                log.err("Call to podman exited with: {}", .{code});
                log.err("stderr output: {s}", .{stderr});
                log.err("argv was: {s}", .{argv_str.items});
                return errors.PodmanErrors.PodmanFailed;
            }
        },
        else => |code| {
            log.err("Podman exited unexpectedly with {any}\n{s}\n{s}\n", .{ code, result.stdout, result.stderr });
            return errors.PodmanErrors.PodmanUnexpectedExit;
        },
    }
}
test "call" {
    const msg = "Hello";
    const example = [_][]const u8{
        "echo",
        msg,
    };
    const result = try call(std.testing.allocator, &example);
    defer std.testing.allocator.free(result);
    std.testing.expect(std.mem.eql(u8, msg ++ "\n", result)) catch |err| {
        std.debug.print("{s}", .{result});
        return err;
    };
}

const create_base = [_][]const u8{
    "podman",
    "create",
    "--cgroupns",
    "host",
    "--dns",
    "none",
    "--ipc",
    "host",
    "--network",
    "host",
    "--no-hosts",
    "--pid",
    "host",
    "--privileged",
    "--security-opt",
    "label=disable",
    "--ulimit",
    "host",
    "--userns",
    "keep-id",
    "--user",
    "root:root",
    "--name",
};

pub fn deleteImage(allocator: std.mem.Allocator, id: []const u8, force: bool) (std.process.Child.RunError || errors.PodmanErrors)!void {
    const base_argv = [_][]const u8{
        "podman",
        "image",
        "rm",
        "--ignore",
    };
    const argv = base_argv ++ if (force) [_][]const u8{"--force"} else [_][]const u8{} ++ [_][]const u8{id};
    const stdout = try call(allocator, argv);
    allocator.free(stdout);
}

pub fn deleteContainer(allocator: std.mem.Allocator, id: []const u8, force: bool) (std.process.Child.RunError || errors.PodmanErrors)!void {
    const base_argv = [_][]const u8{
        "podman",
        "container",
        "rm",
        "--ignore",
    };
    const argv = try std.mem.concat(allocator, []const u8, &[_][]const []const u8{
        &base_argv,
        if (force) &[_][]const u8{"--force"} else &[_][]const u8{},
        &[_][]const u8{id},
    });
    defer allocator.free(argv);
    const stdout = try call(allocator, argv);
    allocator.free(stdout);
}

pub fn startContainer(allocator: std.mem.Allocator, id: []const u8) (std.process.Child.RunError || errors.PodmanErrors)!void {
    const argv = [_][]const u8{
        "podman",
        "container",
        "start",
        id,
    };
    const stdout = try call(allocator, &argv);
    allocator.free(stdout);
}

pub fn stopContainer(allocator: std.mem.Allocator, id: []const u8) (std.process.Child.RunError || errors.PodmanErrors)!void {
    const argv = [_][]const u8{
        "podman",
        "container",
        "stop",
        "--ignore",
        id,
    };
    const stdout = try call(allocator, &argv);
    allocator.free(stdout);
}

pub fn createContainer(args: struct {
    allocator: std.mem.Allocator,
    env: std.process.EnvMap,
    key: []const u8,
    name: []const u8,
    image: Image,
    entrypoint_argv: []const []const u8,
    mounts: []const Mount,
}) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(args.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const envs = try createEnvironmentArgs(arena_allocator, args.env);
    const labels = try createLabelsArgs(arena_allocator, args.key);
    const mounts = try createMountArgs(arena_allocator, args.mounts);

    const base = create_base ++ [_][]const u8{
        args.name,
    };

    const argv = try std.mem.concat(arena_allocator, []const u8, &[_][]const []const u8{
        &base,
        envs.items,
        labels.items,
        mounts.items,
        &[_][]const u8{
            args.image.getId(),
        },
        args.entrypoint_argv,
    });

    // should just return the argv as a string under testing
    const result = if (!builtin.is_test) try call(args.allocator, argv) else try std.mem.concat(args.allocator, u8, argv);
    errdefer args.allocator.free(result);
    if (result.len > 0) {
        if (result[result.len - 1] == '\n') {
            const shortened = try args.allocator.dupe(u8, result[0 .. result.len - 1]);
            args.allocator.free(result);
            return shortened;
        } else {
            return result;
        }
    } else {
        return result;
    }
}

test createContainer {
    var helper_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer helper_arena.deinit();
    const helper_allocator = helper_arena.allocator();
    // setup
    const mounts = [_]Mount{
        Mount{
            .destination = "/test",
            .source = "/test",
            .kind = .{ .devpts = .{} },
            .options = .{ .rw = true },
            .propagation = .none,
        },
    };
    const expected_mounts = try std.mem.concat(helper_allocator, u8, (try createMountArgs(helper_allocator, &mounts)).items);

    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    try env.put("XDG_RUNTIME_DIR", "/run/hi");
    const expected_env = try std.mem.concat(helper_allocator, u8, (try createEnvironmentArgs(helper_allocator, env)).items);

    const image = Image{
        .minimal = .{
            .allocator = undefined,
            .id = "hello",
            .created = undefined,
            .names = undefined,
        },
    };

    const entrypoint_argv = [_][]const u8{
        "test",
        "test",
    };
    const expected_entry = try std.mem.concat(helper_allocator, u8, &entrypoint_argv);

    const key = "key";
    const expected_labels = try std.mem.concat(helper_allocator, u8, (try createLabelsArgs(helper_allocator, key)).items);

    const name = "name";

    const expected_base = try std.mem.concat(helper_allocator, u8, &create_base);

    const expected = try std.mem.concat(helper_allocator, u8, &[_][]const u8{
        expected_base,
        name,
        expected_env,
        expected_labels,
        expected_mounts,
        image.minimal.id,
        expected_entry,
    });

    // do
    const args = try createContainer(.{
        .allocator = std.testing.allocator,
        .entrypoint_argv = &entrypoint_argv,
        .env = env,
        .image = image,
        .mounts = &mounts,
        .key = key,
        .name = name,
    });
    defer std.testing.allocator.free(args);

    // check
    try std.testing.expectEqualStrings(expected, args);
}

fn createEnvironmentArgs(allocator: std.mem.Allocator, env: std.process.EnvMap) errors.CreationErrors!std.ArrayList([]const u8) {
    const minimum_env = [_][]const u8{
        "XDG_RUNTIME_DIR",
    };

    var result = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (result.items) |e| {
            result.allocator.free(e);
        }
        result.deinit();
    }
    for (minimum_env) |key| {
        if (!env.hash_map.contains(key)) {
            log.err("necessary environment variable for container creation not found: {s}\n", .{key});
            return errors.CreationErrors.NeededEnvironmentVariableNotFound;
        }
    }
    var iter = env.iterator();
    while (iter.next()) |entry| {
        const op = try result.allocator.dupe(u8, "--env");
        result.append(op) catch |err| {
            result.allocator.free(op);
            return err;
        };
        try utils.append_format(&result, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
    }
    return result;
}

test createEnvironmentArgs {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    const key1 = "abc";
    const value1 = "efg";
    try env.put(key1, value1);
    try std.testing.expectError(error.NeededEnvironmentVariableNotFound, createEnvironmentArgs(std.testing.allocator, env));
    const key2 = "XDG_RUNTIME_DIR";
    const value2 = "abcdef";
    try env.put(key2, value2);
    const cli = try createEnvironmentArgs(std.testing.allocator, env);
    defer {
        for (cli.items) |e| {
            std.testing.allocator.free(e);
        }
        cli.deinit();
    }
    try std.testing.expectEqual(4, cli.items.len);
    try std.testing.expectEqualStrings("--env", cli.items[0]);
    try std.testing.expectEqualStrings("--env", cli.items[2]);
    const pair1 = key1 ++ "=" ++ value1;
    const pair2 = key2 ++ "=" ++ value2;
    if (std.mem.eql(u8, pair1, cli.items[1])) {
        try std.testing.expectEqualStrings(pair1, cli.items[1]);
        try std.testing.expectEqualStrings(pair2, cli.items[3]);
    } else {
        try std.testing.expectEqualStrings(pair2, cli.items[1]);
        try std.testing.expectEqualStrings(pair1, cli.items[3]);
    }
}

fn createLabelsArgs(allocator: std.mem.Allocator, key: []const u8) std.mem.Allocator.Error!std.ArrayList([]const u8) {
    var result = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (result.items) |e| {
            allocator.free(e);
        }
        result.deinit();
    }

    const marker = "--label";

    {
        const marker_copy = try allocator.dupe(u8, marker);
        result.append(marker_copy) catch |err| {
            allocator.free(marker_copy);
            return err;
        };
        const arg = try std.mem.concat(allocator, u8, &[_][]const u8{ label ++ "=", key });
        result.append(arg) catch |err| {
            allocator.free(arg);
            return err;
        };
    }

    return result;
}

test createLabelsArgs {
    const key = "hello";
    const labels = try createLabelsArgs(std.testing.allocator, key);
    defer {
        for (labels.items) |e| {
            std.testing.allocator.free(e);
        }
        labels.deinit();
    }

    try std.testing.expectEqual(2, labels.items.len);
    try std.testing.expectEqualStrings("--label", labels.items[0]);
    try std.testing.expectEqualStrings(label ++ "=" ++ key, labels.items[1]);
}

fn createMountArgs(allocator: std.mem.Allocator, mounts: []const Mount) std.mem.Allocator.Error!std.ArrayList([]const u8) {
    var result = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (result.items) |e| {
            allocator.free(e);
        }
        result.deinit();
    }

    for (mounts) |mount| {
        var arg = std.ArrayList(u8).init(allocator);
        errdefer arg.deinit();
        const writer = arg.writer();
        try writer.writeAll("--mount=type=");
        switch (mount.kind) {
            .bind => |bind_mount| {
                try writer.writeAll("bind,");
                if (!bind_mount.recursive) {
                    try writer.writeAll("bind-nonrecursive,");
                }
                try writer.print("source={s}", .{mount.source});
            },
            .volume => |volume_mount| {
                try writer.print("volume,source={s}", .{volume_mount.name});
            },
            .devpts => {
                try writer.writeAll("devpts");
            },
        }
        try writer.print(",destination={s},ro={}", .{
            mount.destination,
            !mount.options.rw,
        });
        if (mount.options.dev) {
            try writer.writeAll(",dev");
        }
        if (mount.options.exec) {
            try writer.writeAll(",exec");
        }
        if (mount.options.suid) {
            try writer.writeAll(",suid");
        }
        if (mount.propagation != .none) {
            try writer.writeByte(',');
            try writer.writeAll(@tagName(mount.propagation));
        }
        const as_slice = try arg.toOwnedSlice();
        errdefer allocator.free(as_slice);
        try result.append(as_slice);
    }

    return result;
}

test createMountArgs {
    const vol = Mount{
        .source = "/root/.local/share/containers/storage/volumes/dsgdsfgdfsg/_data",
        .destination = "/run/test",
        .options = .{
            .dev = true,
            .exec = false,
            .rw = false,
            .suid = true,
        },
        .propagation = .none,
        .kind = .{ .volume = .{ .name = "vol1" } },
    };
    const vol_expected = "--mount=type=volume,source=vol1,destination=/run/test,ro=true,dev,suid";
    const bind = Mount{
        .source = "/root/Documents",
        .destination = "/root/Documents",
        .options = .{
            .dev = false,
            .exec = true,
            .rw = true,
            .suid = false,
        },
        .propagation = .rprivate,
        .kind = .{ .bind = .{ .recursive = true } },
    };
    const bind_expected = "--mount=type=bind,source=/root/Documents,destination=/root/Documents,ro=false,exec,rprivate";
    const devpts = Mount{
        .source = "something",
        .destination = "/dev/pts",
        .options = .{
            .rw = false,
        },
        .propagation = .runbindable,
        .kind = .{ .devpts = .{} },
    };
    const devpts_expected = "--mount=type=devpts,destination=/dev/pts,ro=true,exec,runbindable";
    const actual = try createMountArgs(std.testing.allocator, &[_]Mount{ vol, bind, devpts });
    defer {
        for (actual.items) |e| {
            std.testing.allocator.free(e);
        }
        actual.deinit();
    }
    try std.testing.expectEqual(3, actual.items.len);
    try std.testing.expectEqualStrings(vol_expected, actual.items[0]);
    try std.testing.expectEqualStrings(bind_expected, actual.items[1]);
    try std.testing.expectEqualStrings(devpts_expected, actual.items[2]);
}

pub fn createRunArgs(allocator: std.mem.Allocator, id: []const u8, command: []const []const u8, ttyNeeded: bool, env: std.process.EnvMap, work_dir: []const u8, username: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var result = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (result.items) |e| {
            allocator.free(e);
        }
        result.deinit();
    }

    for ([_][]const u8{
        "podman",
        "container",
        "exec",
        "--interactive",
    }) |e| {
        try utils.appendClone(&result, e);
    }

    try utils.appendClone(&result, "--workdir");
    try utils.appendClone(&result, work_dir);
    try utils.appendClone(&result, "--user");
    try utils.appendClone(&result, username);

    if (ttyNeeded) {
        try utils.appendClone(&result, "--tty");
    }

    var iter = env.iterator();
    while (iter.next()) |entry| {
        try utils.appendClone(&result, "--env");
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();
        try (buffer.writer().print("{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }));
        const arg = try buffer.toOwnedSlice();
        errdefer allocator.free(arg);
        try result.append(arg);
    }

    try utils.appendClone(&result, id);

    for (command) |e| {
        try utils.appendClone(&result, e);
    }

    return try result.toOwnedSlice();
}
