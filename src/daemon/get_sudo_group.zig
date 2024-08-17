const std = @import("std");
const log = @import("logging");

pub fn get_sudo_group() (std.fs.File.OpenError || std.fs.File.ReadError || error{ NoSudoGroupFound, GroupFileProblem })![]const u8 {
    const possible_group_names = [_][]const u8{
        "sudo",
        "wheel",
    };
    var file = try std.fs.openFileAbsolute("/etc/group", .{ .mode = .read_only });
    defer file.close();
    var br = std.io.bufferedReader(file.reader());
    var reader = br.reader();
    var buffer: [std.os.linux.NAME_MAX]u8 = undefined;
    var writer = std.io.fixedBufferStream(&buffer);
    while (reader.streamUntilDelimiter(writer.writer(), ':', buffer.len)) {
        const group = writer.getWritten();
        for (possible_group_names) |possibility| {
            if (std.mem.eql(u8, group, possibility)) {
                return possibility;
            }
        }
        writer.reset();
        try reader.skipUntilDelimiterOrEof('\n');
    } else |err| {
        switch (err) {
            error.StreamTooLong, error.NoSpaceLeft => {
                log.err("encountered too long group name or invalid /etc/group file\n", .{});
                return error.GroupFileProblem;
            },
            error.EndOfStream => {
                log.err("no sudo group found\n", .{});
                return error.NoSudoGroupFound;
            },
            else => |rest| return rest,
        }
    }
}

test "get_sudo_group" {
    const group = try get_sudo_group();
    if (!(std.mem.eql(u8, "sudo", group) or std.mem.eql(u8, "wheel", group))) {
        return error.InvalidGroup;
    }
}
