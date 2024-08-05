const std = @import("std");

pub fn isInsideContainer() bool {
    return fileExists("/run/.containerenv");
}

pub fn isInsideNexpodContainer() bool {
    return fileExists("/run/.nexpodenv");
}

fn fileExists(path: []const u8) bool {
    if (std.fs.accessAbsolute(path, .{})) {
        return true;
    } else |_| {
        return false;
    }
}

test "fileExists" {
    const path = "/tmp/nexpodtest";
    (try std.fs.createFileAbsolute(path, .{})).close();
    defer std.fs.deleteFileAbsolute(path) catch unreachable;

    try std.testing.expect(fileExists(path));
}
