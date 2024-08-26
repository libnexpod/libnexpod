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
            .name = "run-Env-Var",
            .image = img,
        });
        defer {
            con.delete(true) catch |err| std.log.err("error encountered while deleting container: {s}", .{@errorName(err)});
            con.deinit();
        }

        try con.start();

        const variable = "TEST_VAR";
        const value = "This is the value";
        var env = try std.process.getEnvMap(allocator);
        defer env.deinit();
        try env.put(variable, value);

        var process, const argv = try con.runCommand(.{
            .allocator = allocator,
            .argv = &[_][]const u8{
                "bash",
                "-c",
                "echo $" ++ variable,
            },
            .stdin_behaviour = .Ignore,
            .stdout_behaviour = .Pipe,
            .stderr_behaviour = .Pipe,
            .working_dir = "/",
            .env = &env,
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
        try std.testing.expectEqualStrings(value ++ "\n", stdout.items);
    }
}
