const std = @import("std");
const libnexpod = @import("libnexpod");

pub const std_options: std.Options = .{
    .log_level = switch(@import("options").logLevel) {
        0 => .debug,
        1 => .info,
        2 => .warn,
        3 => .err,
        else => unreachable,
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.log.err("leak detected", .{});
    };
    const allocator = gpa.allocator();

    var nps = try libnexpod.openLibnexpodStorage(allocator, "libnexpod-systemtest");
    defer nps.deinit();

    const images = try nps.getImageList();
    defer {
        for (images) |img| {
            img.deinit();
        }
        allocator.free(images);
    }
    // this should be at least one thanks to the setup, but it may be more if the developer has some on their machine
    try std.testing.expect(images.len >= 1);
}
