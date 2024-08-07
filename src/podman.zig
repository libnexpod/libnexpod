const std = @import("std");
const log = @import("logging.zig");
const errors = @import("errors.zig");

const img_label = "com.github.kilianhanich.nexpod";

pub fn getImages(allocator: std.mem.Allocator) (std.process.Child.RunError || errors.PodmanErrors)!std.ArrayList([]const u8) {
    const get_ids_argv = [_][]const u8{
        "podman",
        "images",
        "--format",
        "{{ .Id }}",
        "--filter",
        "label=" ++ img_label,
    };
    const result = call(allocator, &get_ids_argv) catch |err| switch (err) {
        error.FileNotFound => {
            log.err("podman not found\n", .{});
            return errors.PodmanErrors.NotFound;
        },
        else => return err,
    };
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    const ids = e: {
        switch (result.term) {
            .Exited => |code| {
                if (code == 0) {
                    break :e result.stdout;
                } else {
                    log.err("Call to podman exited with: {}\n{s}\n", .{ code, result.stderr });
                    return errors.PodmanErrors.Failed;
                }
            },
            else => |code| {
                log.err("Podman exited unexpectedly with {any}\n{s}\n{s}\n", .{ code, result.stdout, result.stderr });
                return errors.PodmanErrors.UnexpectedExit;
            },
        }
    };

    var list = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (list.items) |img| {
            allocator.free(img);
        }
        list.deinit();
    }
    var iter = std.mem.tokenizeAny(u8, ids, "\n");
    while (iter.next()) |id| {
        const inspect_argv = [_][]const u8{
            "podman",
            "image",
            "inspect",
            "--format",
            "{{ json . }}",
            id,
        };
        // podman can't be missing here anymore
        const inspect_result = try call(allocator, &inspect_argv);
        defer allocator.free(inspect_result.stderr);
        errdefer allocator.free(inspect_result.stdout);

        try list.append(e: {
            switch (inspect_result.term) {
                .Exited => |code| {
                    if (code == 0) {
                        break :e inspect_result.stdout;
                    } else {
                        log.err("Call to podman exited with: {}\n{s}\n", .{ code, inspect_result.stderr });
                        return errors.PodmanErrors.Failed;
                    }
                },
                else => |code| {
                    log.err("Podman exited unexpectedly with {any}\n{s}\n{s}\n", .{ code, inspect_result.stdout, inspect_result.stderr });
                    return errors.PodmanErrors.UnexpectedExit;
                },
            }
        });
    }
    return list;
}

test "getImages leaktest" {
    const images = try getImages(std.testing.allocator);
    for (images.items) |e| {
        std.testing.allocator.free(e);
    }
    images.deinit();
}

fn call(allocator: std.mem.Allocator, argv: []const []const u8) std.process.Child.RunError!std.process.Child.RunResult {
    return std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    });
}
test "call" {
    const msg = "Hello";
    const example = [_][]const u8{
        "echo",
        msg,
    };
    const result = try call(std.testing.allocator, &example);
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    std.testing.expect(std.mem.eql(u8, msg ++ "\n", result.stdout)) catch |err| {
        std.debug.print("{s}", .{result.stdout});
        return err;
    };
    std.testing.expect(std.mem.eql(u8, "", result.stderr)) catch |err| {
        std.debug.print("{s}", .{result.stderr});
        return err;
    };
}
