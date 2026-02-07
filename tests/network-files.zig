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

fn checkOne(gpa: std.mem.Allocator, path: []const u8, con: *libnexpod.Container) !void {
    const max_bytes = comptime std.math.pow(usize, 2, 32);

    var host_file = try std.fs.openFileAbsolute(path, .{});
    defer host_file.close();
    var host_file_reader = host_file.reader(&.{});
    const host_contents = try host_file_reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(host_contents);

    var process, const argv = try con.runCommand(.{
        .allocator = gpa,
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
            gpa.free(arg);
        }
        gpa.free(argv);
    }

    var stdout = std.ArrayListUnmanaged(u8).empty;
    defer stdout.deinit(gpa);
    var stderr = std.ArrayListUnmanaged(u8).empty;
    defer stderr.deinit(gpa);
    try process.collectOutput(gpa, &stdout, &stderr, max_bytes);

    _ = try process.wait();

    try std.testing.expectEqualStrings("", stderr.items);
    try std.testing.expectEqualStrings(host_contents, stdout.items);
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
