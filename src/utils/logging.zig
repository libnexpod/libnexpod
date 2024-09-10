const std = @import("std");
const builtin = @import("builtin");

const libnexpod_log = std.log.scoped(.libnexpod);

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
