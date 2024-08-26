const std = @import("std");
const libnexpod = @import("libnexpod");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.log.err("leak detected", .{});
    };
    const allocator = gpa.allocator();

    var nps = try libnexpod.openNexpodStorage(allocator, "libnexpod-test");
    defer nps.deinit();

    const images = try nps.getImages();
    defer {
        for (images.items) |img| {
            img.deinit();
        }
        images.deinit();
    }

    if (images.items.len > 0) {
        const img = images.items[0];

        var con = try nps.createContainer(.{
            .name = "list-container",
            .image = img,
        });
        defer {
            con.delete(true) catch |err| std.log.err("error encountered while deleting container: {s}", .{@errorName(err)});
            con.deinit();
        }

        const containers = try nps.getContainers();
        defer {
            for (containers.items) |cont| {
                cont.deinit();
            }
            containers.deinit();
        }

        // there must be at least one, but not at maximum one because the other tests exist
        try std.testing.expect(containers.items.len >= 1);
    }
}
