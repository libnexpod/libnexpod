const std = @import("std");

pub export fn isInsideContainer() bool {
    if (std.fs.accessAbsolute("/run/.containerenv", .{})) {
        return true;
    } else {
        return false;
    }
}

pub export fn isInsideNexpodContainer() bool {
    if (std.fs.accessAbsolute("/run/.nexpodenv", .{})) {
        return true;
    } else {
        return false;
    }
}
