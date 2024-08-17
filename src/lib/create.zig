const std = @import("std");
const errors = @import("errors.zig");
const log = @import("logging");
const utils = @import("utils");
const Image = @import("image.zig");
const Container = @import("container.zig");

pub fn create(allocator: std.mem.Allocator, image: Image, args: struct {
    env: ?*std.process.EnvMap = null,
}) !Container {
    const env = try create_environment_args(allocator, args.env);
    defer env.deinit();
    const id = image.id;
    _ = id;
}

fn create_environment_args(allocator: std.mem.Allocator, op_env: ?*std.process.EnvMap) !std.ArrayList([]const u8) {
    const minimum_env = [_][]const u8{
        "XDG_RUNTIME_DIR",
    };
    const not_found_msg = comptime "necessary environment variable for container creation not found: {}";

    var result = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (result.items) |e| {
            result.allocator.free(e);
        }
        result.deinit();
    }
    if (op_env) |env| {
        for (minimum_env) |key| {
            if (!env.hash_map.contains(key)) {
                log.err(not_found_msg, .{key});
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
    } else {
        var env = try std.process.getEnvMap(allocator);
        defer env.deinit();

        for (minimum_env) |key| {
            if (env.get(key)) |value| {
                const op = try result.allocator.dupe(u8, "--env");
                result.append(op) catch |err| {
                    result.allocator.free(op);
                    return err;
                };
                try utils.append_format(&result, "{s}={s}", .{ key, value });
            } else {
                log.err(not_found_msg, .{key});
                return error.CreationErrors.NeededEnvironmentVariableNotFound;
            }
        }
    }
    return result;
}
