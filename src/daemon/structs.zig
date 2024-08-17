const std = @import("std");
const clap = @import("clap");

pub const Group = struct {
    gid: std.posix.gid_t,
    name: []const u8,
    pub fn parse(in: []const u8) error{ ParseGroupError, Overflow, InvalidCharacter }!Group {
        const divider = std.mem.indexOf(u8, in, "=");
        if (divider) |index| {
            if (!(0 < index and index + 1 < in.len)) {
                return error.ParseGroupError;
            }
            return .{
                .gid = try (clap.parsers.int(u32, 0)(in[0..index])),
                .name = in[index + 1 .. in.len],
            };
        } else {
            return error.ParseGroupError;
        }
    }
};

pub const Info = struct {
    uid: std.posix.uid_t,
    group: std.ArrayList(Group),
    user: []const u8,
    shell: []const u8,
    home: []const u8,
    @"permanents-moved-to-var": bool,
    @"media-link": bool,
};

test "Group.parse" {
    const expected = Group{
        .gid = 5,
        .name = "test",
    };
    const actual = try Group.parse("5=" ++ expected.name);
    try std.testing.expectEqual(expected.gid, actual.gid);
    try std.testing.expectEqualStrings(expected.name, actual.name);
    try std.testing.expectError(error.ParseGroupError, Group.parse("5="));
    try std.testing.expectError(error.ParseGroupError, Group.parse("=a"));
    try std.testing.expectError(error.InvalidCharacter, Group.parse("a=a"));
    try std.testing.expectError(error.Overflow, Group.parse("50000000000000000000000000=a"));
}
