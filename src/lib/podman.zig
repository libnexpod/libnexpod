const std = @import("std");
const log = @import("logging");
const errors = @import("errors.zig");

const label = "com.github.kilianhanich.nexpod";

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

fn call(allocator: std.mem.Allocator, argv: []const []const u8) (std.process.Child.RunError || errors.PodmanErrors)![]const u8 {
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
                log.err("Call to podman exited with: {}\n{s}\n", .{ code, result.stderr });
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
