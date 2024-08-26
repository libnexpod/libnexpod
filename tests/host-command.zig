const std = @import("std");
const libnexpod = @import("libnexpod");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.log.err("leak detected", .{});
    };
    const allocator = gpa.allocator();

    const key = "libnexpod-test";
    const name = "host-command";
    const container_name = key ++ "-" ++ name;

    const nps = try libnexpod.openNexpodStorage(allocator, key);
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
            .name = name,
            .image = img,
        });
        defer {
            con.delete(true) catch |err| std.log.err("error encountered while deleting container: {s}", .{@errorName(err)});
            con.deinit();
        }

        try con.start();

        // if you really think about it, the amounts of indirections (especially if you run this command inside of a container) is insane
        var process, const argv = try con.runCommand(.{
            .allocator = allocator,
            .argv = &[_][]const u8{
                "podman",
                "container",
                "inspect",
                "--format",
                "{{.Name}}",
                con.getId(),
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

        const max_bytes = comptime std.math.pow(usize, 2, 32);

        var stdout = std.ArrayList(u8).init(allocator);
        defer stdout.deinit();
        var stderr = std.ArrayList(u8).init(allocator);
        defer stderr.deinit();
        try process.collectOutput(&stdout, &stderr, max_bytes);

        _ = try process.wait();

        try std.testing.expectEqualStrings("", stderr.items);
        try std.testing.expectEqualStrings(container_name ++ "\n", stdout.items);
    }
}
