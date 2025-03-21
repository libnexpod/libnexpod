const std = @import("std");
const builtin = @import("builtin");
const log = @import("logging");
const utils = @import("utils");
const errors = @import("errors.zig");
const Mount = @import("container.zig").Mount;
const Image = @import("image.zig").Image;

const label = "com.github.libnexpod";

pub fn call(allocator: std.mem.Allocator, argv: []const []const u8) (std.process.Child.RunError || errors.PodmanErrors)![]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = comptime std.math.maxInt(usize),
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
test call {
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

pub fn deleteImage(allocator: std.mem.Allocator, id: []const u8, force: bool) (std.process.Child.RunError || errors.PodmanErrors)!void {
    const base_argv = [_][]const u8{
        "podman",
        "image",
        "rm",
        "--ignore",
    };
    const argv = base_argv ++ if (force) [_][]const u8{"--force"} else [_][]const u8{} ++ [_][]const u8{id};
    const stdout = try call(allocator, argv);
    log.debug("deleteImage received the following from podman: {s}", .{stdout});
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
    log.debug("deleteContainer received the following from podman: {s}", .{stdout});
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
    log.debug("startContainer received the following from podman: {s}", .{stdout});
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
    log.debug("stopContainer received the following from podman: {s}", .{stdout});
    allocator.free(stdout);
}

pub fn createRunArgs(allocator: std.mem.Allocator, id: []const u8, command: []const []const u8, ttyNeeded: bool, env: std.process.EnvMap, work_dir: []const u8, username: []const u8) std.mem.Allocator.Error![]const []const u8 {
    var result = std.ArrayListUnmanaged([]const u8).empty;
    errdefer {
        for (result.items) |e| {
            allocator.free(e);
        }
        result.deinit(allocator);
    }

    for ([_][]const u8{
        "podman",
        "container",
        "exec",
        "--interactive",
    }) |e| {
        try utils.appendClone(allocator, &result, e);
    }

    try utils.appendClone(allocator, &result, "--workdir");
    try utils.appendClone(allocator, &result, work_dir);
    try utils.appendClone(allocator, &result, "--user");
    try utils.appendClone(allocator, &result, username);

    if (ttyNeeded) {
        try utils.appendClone(allocator, &result, "--tty");
    }

    var iter = env.iterator();
    while (iter.next()) |entry| {
        try utils.appendClone(allocator, &result, "--env");
        const arg = try std.fmt.allocPrint(allocator, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
        errdefer allocator.free(arg);
        try result.append(allocator, arg);
    }

    try utils.appendClone(allocator, &result, id);

    for (command) |e| {
        try utils.appendClone(allocator, &result, e);
    }

    return try result.toOwnedSlice(allocator);
}
