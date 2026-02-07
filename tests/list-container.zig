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
    var args = try std.process.ArgIterator.initWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();
    const libnexpodd = args.next().?;

    var nps = try libnexpod.openLibnexpodStorage(allocator, "libnexpod-systemtest");
    defer nps.deinit();

    const images = try nps.getImageList();
    defer {
        for (images) |img| {
            img.deinit();
        }
        allocator.free(images);
    }

    if (images.len > 0) {
        const img = images[0];

        var con = try nps.createContainer(.{
            .name = "list-container",
            .image = img,
            .libnexpodd_path = libnexpodd,
        });
        defer {
            con.delete(true) catch |err| std.log.err("error encountered while deleting container: {s}", .{@errorName(err)});
            con.deinit();
        }

        const containers = try nps.getContainerList();
        defer {
            for (containers) |cont| {
                cont.deinit();
            }
            allocator.free(containers);
        }

        // there must be at least one, but not at maximum one because the other tests exist
        try std.testing.expect(containers.len >= 1);
    }
}
