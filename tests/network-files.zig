const std = @import("std");
const libnexpod = @import("libnexpod");

fn checkOne(allocator: std.mem.Allocator, path: []const u8, con: *libnexpod.Container) !void {
    const max_bytes = comptime std.math.pow(usize, 2, 32);

    var host_contents = std.ArrayList(u8).init(allocator);
    defer host_contents.deinit();
    var host_file = try std.fs.openFileAbsolute(path, .{});
    defer host_file.close();
    try host_file.reader().readAllArrayList(&host_contents, max_bytes);

    var process, const argv = try con.runCommand(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "cat",
            path,
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

    var stdout = std.ArrayListUnmanaged(u8).empty;
    defer stdout.deinit(allocator);
    var stderr = std.ArrayListUnmanaged(u8).empty;
    defer stderr.deinit(allocator);
    try process.collectOutput(allocator, &stdout, &stderr, max_bytes);

    _ = try process.wait();

    try std.testing.expectEqualStrings("", stderr.items);
    try std.testing.expectEqualStrings(host_contents.items, stdout.items);
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
            .name = "network-files",
            .image = img,
            .libnexpodd_path = libnexpodd,
        });
        defer {
            con.delete(true) catch |err| std.log.err("error encountered while deleting container: {s}", .{@errorName(err)});
            con.deinit();
        }

        try con.start();
        try nps.updateContainer(&con);

        for ([_][]const u8{
            "/etc/hosts",
            "/etc/resolv.conf",
            "/etc/host.conf",
            "/etc/hostname",
        }) |path| {
            try checkOne(allocator, path, &con);
        }
    }
}
