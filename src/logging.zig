const std = @import("std");
const builtin = @import("builtin");

const nexpod_log = std.log.scoped(.nexpod);

pub fn err(comptime format: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        nexpod_log.err(format, args);
    }
}

pub fn warn(comptime format: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        nexpod_log.warn(format, args);
    }
}

pub fn info(comptime format: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        nexpod_log.info(format, args);
    }
}

pub fn debug(comptime format: []const u8, args: anytype) void {
    if (!builtin.is_test) {
        nexpod_log.debug(format, args);
    }
}
