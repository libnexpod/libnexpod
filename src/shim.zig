const std = @import("std");

fn create_argv(allocator: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    const base = [_][]const u8{ "flatpak-spawn", "--host" };
    const argv = try std.mem.concat(allocator, []const u8, &[_][]const []const u8{ &base, args });
    return argv;
}

test "create_argv" {
    const example_input = [_][]const u8{ "hello", "this", "is", "a", "test" };
    const expected_output = .{ "flatpak-spawn", "--host" } ++ example_input;
    const proper = try create_argv(std.testing.allocator, &example_input);
    defer std.testing.allocator.free(proper);
    for (proper, expected_output) |to_test, expected| {
        try std.testing.expect(std.mem.eql(u8, to_test, expected));
    }
    try std.testing.expectError(error.OutOfMemory, create_argv(std.testing.failing_allocator, &example_input));
}

fn handle(allocator: std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(allocator);
    const argv = try create_argv(allocator, args);
    const envs = try std.process.getEnvMap(allocator);
    return std.process.execve(allocator, argv, &envs);
}

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const stderr = std.io.getStdErr().writer();
    handle(arena.allocator()) catch |err| {
        stderr.print("nexpod-host-shim: {s}...\n", .{switch (err) {
            error.FileNotFound => "flatpak-spawn: command not found",
            error.AccessDenied => "flatpak-spawn: access denied",
            error.ProcessFdQuotaExceeded => "ProcessFdQuotaExceeded",
            error.SystemFdQuotaExceeded => "SystemFdQuotaExceeded",
            error.Overflow, error.OutOfMemory => "out of memory",
            error.Unexpected => "unexpected error",
            error.SystemResources => "above system resource limit",
            error.InvalidExe => "flatpak-spawn: invalid executable",
            error.FileSystem => "filesystem error",
            error.IsDir => "flatpak-spawn: is a directory",
            error.NotDir => "flatpak-spawn: invalid path",
            error.FileBusy => "flatpak-spawn: file busy",
            error.NameTooLong => "flatpak-spawn: name too long",
        }}) catch unreachable;
    };
}
