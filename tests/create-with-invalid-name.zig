const std = @import("std");
const libnexpod = @import("libnexpod");

pub const std_options = .{
    .logFn = logFilter,
};

var libnexpod_logs: u8 = 0;
fn logFilter(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (scope == .libnexpod) {
        libnexpod_logs += 1;
    } else {
        std.log.defaultLog(level, scope, format, args);
    }
}

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

    const nps = try libnexpod.openLibnexpodStorage(allocator, "libnexpod-systemtest");
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

        try std.testing.expectError(libnexpod.errors.PodmanErrors.PodmanFailed, nps.createContainer(.{
            .name = "äß",
            .image = img,
            .libnexpodd_path = libnexpodd,
        }));
        try std.testing.expectEqual(3, libnexpod_logs);
    }
}
