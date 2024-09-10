const std = @import("std");
const libnexpod = @import("libnexpod");

fn checkOne(allocator: std.mem.Allocator, con: *libnexpod.Container, ulimit_argv: []const u8) !void {
    const max_bytes = std.math.pow(usize, 2, 32);

    var ulimit = std.process.Child.init(&[_][]const u8{
        "bash",
        "-c",
        ulimit_argv,
    }, allocator);
    ulimit.stdout_behavior = .Pipe;
    try ulimit.spawn();
    var expected = std.ArrayList(u8).init(allocator);
    defer expected.deinit();
    try ulimit.stdout.?.reader().readAllArrayList(&expected, max_bytes);
    _ = try ulimit.wait();

    var process, const argv = try con.runCommand(.{
        .allocator = allocator,
        .argv = &[_][]const u8{
            "flatpak-spawn",
            "--host",
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
            allocator.free(arg);
        }
        allocator.free(argv);
    }

    var stdout = std.ArrayList(u8).init(allocator);
    defer stdout.deinit();
    var stderr = std.ArrayList(u8).init(allocator);
    defer stderr.deinit();
    try process.collectOutput(&stdout, &stderr, max_bytes);

    _ = try process.wait();

    try std.testing.expectEqualStrings("", stderr.items);
    try std.testing.expectEqualStrings(expected.items, stdout.items);
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

        for ([_][]const u8{
            "ulimit -H -R",
            "ulimit -S -R",
            "ulimit -H -c",
            "ulimit -S -c",
            "ulimit -H -d",
            "ulimit -S -d",
            "ulimit -H -e",
            "ulimit -S -e",
            "ulimit -H -f",
            "ulimit -S -f",
            "ulimit -H -i",
            "ulimit -S -i",
            "ulimit -H -l",
            "ulimit -S -l",
            "ulimit -H -m",
            "ulimit -S -m",
            "ulimit -H -n",
            "ulimit -S -n",
            "ulimit -H -p",
            "ulimit -S -p",
            "ulimit -H -q",
            "ulimit -S -q",
            "ulimit -H -r",
            "ulimit -S -r",
            "ulimit -H -s",
            "ulimit -S -s",
            "ulimit -H -t",
            "ulimit -S -t",
            "ulimit -H -u",
            "ulimit -S -u",
            "ulimit -H -v",
            "ulimit -S -v",
            "ulimit -H -x",
            "ulimit -S -x",
        }) |argv| {
            checkOne(allocator, &con, argv) catch |err| {
                std.log.err("ulimit failed on this arg: {s}", .{argv});
                return err;
            };
        }
    }
}
