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

    const nps = try libnexpod.openLibnexpodStorage(allocator, "libnexpod-systemtest");
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
            .name = "run-Hello-World",
            .image = img,
            .libnexpodd_path = libnexpodd,
        });
        defer {
            con.delete(true) catch |err| std.log.err("error encountered while deleting container: {s}", .{@errorName(err)});
            con.deinit();
        }

        try con.start();
        try nps.updateContainer(&con);

        var process, const argv = try con.runCommand(.{
            .allocator = allocator,
            .argv = &[_][]const u8{
                "echo",
                "Hello",
                "World",
            },
            .stdin_behaviour = .Ignore,
            .stdout_behaviour = .Pipe,
            .stderr_behaviour = .Pipe,
            .working_dir = "/",
        });
        defer {
            for (argv) |arg| {
                allocator.free(arg);
            }
            allocator.free(argv);
        }

        const max_bytes = std.math.pow(usize, 2, 32);

        var stdout = std.ArrayListUnmanaged(u8).empty;
        defer stdout.deinit(allocator);
        var stderr = std.ArrayListUnmanaged(u8).empty;
        defer stderr.deinit(allocator);
        try process.collectOutput(allocator, &stdout, &stderr, max_bytes);

        _ = try process.wait();

        try std.testing.expectEqualStrings("", stderr.items);
        try std.testing.expectEqualStrings("Hello World\n", stdout.items);
    }
}
