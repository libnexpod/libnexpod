const std = @import("std");
const builtin = @import("builtin");

const scope = .libnexpod;

const libnexpod_log = std.log.scoped(scope);

pub fn enabled(comptime level: std.log.Level) bool {
    return std.log.logEnabled(level, scope);
}

pub fn err(comptime format: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        libnexpod_log.err(format, args);
    }
}

pub fn warn(comptime format: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        libnexpod_log.warn(format, args);
    }
}

pub fn info(comptime format: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        libnexpod_log.info(format, args);
    }
}

pub fn debug(comptime format: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        libnexpod_log.debug(format, args);
    }
}
