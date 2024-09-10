const std = @import("std");
const libnexpod = @import("libnexpod");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.log.err("leak detected", .{});
    };
    const allocator = gpa.allocator();
    var args = try std.process.ArgIterator.initWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    const nexpodd = args.next().?;

    const nps = try libnexpod.openNexpodStorage(allocator, "libnexpod-systemtest");
    defer nps.deinit();

    var images = try nps.getImages();
    defer {
        for (images.items) |img| {
            img.deinit();
        }
        images.deinit();
    }

    if (images.items.len > 0) {
        const img = images.items[0];

        var con = try nps.createContainer(.{
            .name = "example",
            .image = img,
            .nexpodd_path = nexpodd,
        });
        defer {
            con.delete(true) catch |err| std.log.err("error encountered while deleting container: {s}", .{@errorName(err)});
            con.deinit();
        }

        try std.testing.expectEqual(.Created, con.getStatus());

        try con.start();

        try std.testing.expectEqual(.Running, con.getStatus());

        try con.stop();

        try std.testing.expectEqual(.Exited, con.getStatus());
    }
}
