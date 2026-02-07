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

fn checkOne(gpa: std.mem.Allocator, con: *libnexpod.Container, ulimit_argv: []const u8) !void {
    const max_bytes = std.math.pow(usize, 2, 32);

    var ulimit = std.process.Child.init(&[_][]const u8{
        "bash",
        "-c",
        ulimit_argv,
    }, gpa);
    ulimit.stdout_behavior = .Pipe;
    try ulimit.spawn();
    var ulimitStdout = ulimit.stdout.?.reader(&.{});
    const expected = try ulimitStdout.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(expected);
    _ = try ulimit.wait();

    var process, const argv = try con.runCommand(.{
        .allocator = gpa,
        .argv = &[_][]const u8{
            "bash",
            "-c",
            ulimit_argv,
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
    try std.testing.expectEqualStrings(expected, stdout.items);
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
            .name = "ulimit",
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
            "ulimit -H -R",
            "ulimit -H -c",
            "ulimit -H -d",
            "ulimit -H -e",
            "ulimit -H -f",
            "ulimit -H -i",
            "ulimit -H -l",
            "ulimit -H -m",
            "ulimit -H -n",
            "ulimit -H -p",
            "ulimit -H -q",
            "ulimit -H -r",
            "ulimit -H -s",
            "ulimit -H -t",
            "ulimit -H -u",
            "ulimit -H -v",
            "ulimit -H -x",
        }) |argv| {
            checkOne(allocator, &con, argv) catch |err| {
                std.log.err("ulimit failed on this arg: {s}", .{argv});
                return err;
            };
        }
    }
}
