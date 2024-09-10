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
            .name = "run-interactive",
            .image = img,
            .nexpodd_path = nexpodd,
        });
        defer {
            con.delete(true) catch |err| std.log.err("error encountered while deleting container: {s}", .{@errorName(err)});
            con.deinit();
        }

        try con.start();

        var process, const argv = try con.runCommand(.{
            .allocator = allocator,
            .argv = &[_][]const u8{
                "bash",
                "--login",
            },
            .stdin_behaviour = .Pipe,
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

        var env = try std.process.getEnvMap(allocator);
        defer env.deinit();
        const home_dir = env.get("HOME") orelse {
            std.log.warn("no HOME environment variable, aborting test\n", .{});
            return;
        };

        const stdin = process.stdin.?.writer();
        const script = [_][]const []const u8{
            &[_][]const u8{
                "pwd",
            },
            &[_][]const u8{
                "echo",
                home_dir,
            },
            &[_][]const u8{
                "cd",
            },
            &[_][]const u8{
                "pwd",
            },
            &[_][]const u8{
                "exit",
            },
        };
        for (script) |command| {
            for (command) |c| {
                try stdin.print("{s} ", .{c});
            }
            try stdin.writeByte('\n');
        }

        const max_bytes = comptime std.math.pow(usize, 2, 32);

        var stdout = std.ArrayList(u8).init(allocator);
        defer stdout.deinit();
        var stderr = std.ArrayList(u8).init(allocator);
        defer stderr.deinit();
        try process.collectOutput(&stdout, &stderr, max_bytes);

        _ = try process.wait();

        const expected_output = try std.mem.concat(allocator, u8, &[_][]const u8{
            "/\n",
            home_dir,
            "\n",
            home_dir,
            "\n",
        });
        defer allocator.free(expected_output);
        try std.testing.expectEqualStrings("", stderr.items);
        try std.testing.expectEqualStrings(expected_output, stdout.items);
    }
}
