const std = @import("std");
const libnexpod = @import("libnexpod");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.log.err("leak detected", .{});
    };
    const allocator = gpa.allocator();

    const nps = try libnexpod.openNexpodStorage(allocator, "libnexpod-test");
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
            .name = "host-network",
            .image = img,
        });
        defer {
            con.delete(true) catch |err| std.log.err("error encountered while deleting container: {s}", .{@errorName(err)});
            con.deinit();
        }

        try con.start();

        const path = try std.fmt.allocPrint(allocator, "/proc/{}/ns/net", .{std.os.linux.getpid()});
        defer allocator.free(path);
        var buffer = [_]u8{0} ** std.fs.max_path_bytes;
        const expected = try std.fmt.allocPrint(allocator, "{s}\n", .{try std.posix.readlink(path, &buffer)});
        defer allocator.free(expected);

        var process, const argv = try con.runCommand(.{
            .allocator = allocator,
            .argv = &[_][]const u8{
                "bash",
                "-c",
                "readlink /proc/$$/ns/net",
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

        var stdout = std.ArrayList(u8).init(allocator);
        defer stdout.deinit();
        var stderr = std.ArrayList(u8).init(allocator);
        defer stderr.deinit();
        try process.collectOutput(&stdout, &stderr, max_bytes);

        _ = try process.wait();

        try std.testing.expectEqualStrings("", stderr.items);
        try std.testing.expectEqualStrings(expected, stdout.items);
    }
}
