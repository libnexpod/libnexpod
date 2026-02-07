const std = @import("std");
const log = @import("logging");

pub fn get_sudo_group() (std.fs.File.OpenError || std.fs.File.ReadError || error{ NoSudoGroupFound, GroupFileProblem })![]const u8 {
    const possible_group_names = [_][]const u8{
        "sudo",
        "wheel",
    };
    var file = try std.fs.openFileAbsolute("/etc/group", .{ .mode = .read_only });
    defer file.close();
    var readBuffer: [1024]u8 = undefined;
    var fileReader = file.reader(&readBuffer);
    const reader: *std.Io.Reader = &fileReader.interface;
    while (reader.takeDelimiterExclusive(':')) |groupConstant| {
        var group = groupConstant;
        if (group[0] == '\n') {
            group.ptr += 1;
            group.len -= 1;
        }
        for (possible_group_names) |possibility| {
            if (std.mem.eql(u8, group, possibility)) {
                return possibility;
            }
        }
        _ = reader.discardDelimiterExclusive('\n') catch return fileReader.err.?;
    } else |err| {
        switch (err) {
            error.StreamTooLong => {
                log.err("encountered too long group name or invalid /etc/group file\n", .{});
                return error.GroupFileProblem;
            },
            error.EndOfStream => {
                log.err("no sudo group found\n", .{});
                return error.NoSudoGroupFound;
            },
            else => return fileReader.err.?,
        }
    }
}

test "get_sudo_group" {
    const group = try get_sudo_group();
    if (!(std.mem.eql(u8, "sudo", group) or std.mem.eql(u8, "wheel", group))) {
        return error.InvalidGroup;
    }
}
