const std = @import("std");
const libnexpod = @import("libnexpod");

fn run(comptime key: []const u8, comptime name: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        std.log.err("leak detected", .{});
    };
    const allocator = gpa.allocator();

    const container_name = if (comptime std.mem.eql(u8, "", key))
        name
    else
        key ++ "-" ++ name;

    const nps = try libnexpod.openNexpodStorage(allocator, key);
    defer nps.deinit();

    const images = try nps.getImages();
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

        try std.testing.expectEqualStrings(container_name, con.full.name);
    }
}

pub fn main() !void {
    // while they will have the same name in podman, they don't have according to out key concept
    try run("libnexpod-systemtest", "create-name-correct");
    try run("", "libnexpod-systemtest-create-name-correct");
}
