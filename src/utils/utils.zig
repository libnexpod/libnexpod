const std = @import("std");

pub fn isInsideContainer() bool {
    return fileExists("/run/.containerenv");
}

pub fn isInsideLibnexpodContainer() bool {
    return fileExists("/run/.libnexpodenv");
}

pub fn fileExists(path: []const u8) bool {
    if (std.fs.accessAbsolute(path, .{})) {
        return true;
    } else |_| {
        return false;
    }
}

test "fileExists" {
    const path = "/tmp/libnexpodtest";
    (try std.fs.createFileAbsolute(path, .{})).close();
    defer std.fs.deleteFileAbsolute(path) catch unreachable;

    try std.testing.expect(fileExists(path));
}

pub fn append_format(container: *std.ArrayList([]const u8), comptime format: []const u8, args: anytype) std.mem.Allocator.Error!void {
    const arg = try std.fmt.allocPrint(container.allocator, format, args);
    container.append(arg) catch |err| {
        container.allocator.free(arg);
        return err;
    };
}

pub fn appendClone(container: *std.ArrayList([]const u8), str: []const u8) std.mem.Allocator.Error!void {
    const dupe = try container.allocator.dupe(u8, str);
    errdefer container.allocator.free(str);
    try container.append(dupe);
}

pub fn stringLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test stringLessThan {
    try std.testing.expect(stringLessThan(void{}, "a", "b"));
    try std.testing.expect(stringLessThan(void{}, "1", "2"));
    try std.testing.expect(!stringLessThan(void{}, "b", "a"));
    try std.testing.expect(!stringLessThan(void{}, "2", "1"));
    try std.testing.expect(!stringLessThan(void{}, "b", "b"));
    try std.testing.expect(!stringLessThan(void{}, "2", "2"));
}

pub fn stringCompare(_: void, a: []const u8, b: []const u8) std.math.Order {
    return std.mem.order(u8, a, b);
}

test stringCompare {
    try std.testing.expectEqual(std.math.Order.lt, stringCompare(void{}, "a", "b"));
    try std.testing.expectEqual(std.math.Order.lt, stringCompare(void{}, "1", "2"));
    try std.testing.expectEqual(std.math.Order.gt, stringCompare(void{}, "b", "a"));
    try std.testing.expectEqual(std.math.Order.gt, stringCompare(void{}, "2", "1"));
    try std.testing.expectEqual(std.math.Order.eq, stringCompare(void{}, "b", "b"));
    try std.testing.expectEqual(std.math.Order.eq, stringCompare(void{}, "2", "2"));
}
