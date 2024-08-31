const std = @import("std");
const libnexpod = @import("libnexpod");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.log.err("leak detected", .{});
    };
    const allocator = gpa.allocator();

    var nps = try libnexpod.openNexpodStorage(allocator, "libnexpod-systemtest");
    defer nps.deinit();

    const images = try nps.getImages();
    defer {
        for (images.items) |img| {
            img.deinit();
        }
        images.deinit();
    }
    // this should be at least one thanks to the setup, but it may be more if the developer has some on their machine
    try std.testing.expect(images.items.len >= 1);
}
