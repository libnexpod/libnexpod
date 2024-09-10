const std = @import("std");
const builtin = @import("builtin");
const log = @import("logging");
const utils = @import("utils");
const get_sudo_group = @import("get_sudo_group.zig").get_sudo_group;
const structs = @import("structs.zig");
const Info = structs.Info;
const Group = structs.Group;

pub const EnsureUserErrors = std.fmt.AllocPrintError || std.process.Child.RunError || std.fs.File.OpenError || std.fs.File.ReadError || error{
    GroupaddFailed,
    GroupaddUnexpectedError,
    OutOfMemory,
    NoSudoGroupFound,
    GroupFileProblem,
    UseraddFailed,
    UseraddUnexpectedError,
    UsermodFailed,
    UsermodExpectedError,
    NoShellExists,
};

pub fn ensure_user(allocator: std.mem.Allocator, info: Info) EnsureUserErrors!void {
    const run = if (builtin.is_test) test_child_run else std.process.Child.run;
    const groupadd_argv_template = [_][]const u8{
        "groupadd",
        "--non-unique",
        "--gid",
    };
    for (info.group.items) |group| {
        const gid = try std.fmt.allocPrint(allocator, "{}", .{group.gid});
        defer allocator.free(gid);
        const groupadd_argv = groupadd_argv_template ++ [_][]const u8{
            gid,
            group.name,
        };
        const result = try run(.{
            .allocator = allocator,
            .argv = &groupadd_argv,
        });
        allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        switch (result.term) {
            .Exited => |code| {
                switch (code) {
                    0 => {},
                    9 => {
                        log.info("don't need to create group {s} with GID {s}", .{ group.name, gid });
                    },
                    else => {
                        log.err("groupadd exited with error code {}", .{code});
                        log.err("stderr was: {s}", .{result.stderr});
                        return error.GroupaddFailed;
                    },
                }
            },
            else => |code| {
                log.err("groupadd exited unexpectedly with {}", .{code});
                return error.GroupaddUnexpectedError;
            },
        }
    }
    const sudo_group = try get_sudo_group();
    const uid = try std.fmt.allocPrint(allocator, "{}", .{info.uid});
    defer allocator.free(uid);
    var useradd_argv = std.ArrayList([]const u8).init(allocator);
    defer useradd_argv.deinit();
    const default_shell = "/bin/sh";
    const shell = result: {
        if (!utils.fileExists(info.shell)) {
            break :result info.shell;
        } else if (utils.fileExists(default_shell)) {
            break :result default_shell;
        } else {
            return error.NoShellExists;
        }
    };
    try useradd_argv.appendSlice(&[_][]const u8{
        "useradd",
        "--home-dir",
        info.home,
        "--no-create-home",
        "--shell",
        shell,
        "--uid",
        uid,
        "--gid",
        info.group.items[0].name,
    });
    const additional_groups = val: {
        if (info.group.items.len > 1) {
            try useradd_argv.append("--groups");
            var group_list = std.ArrayList(u8).init(allocator);
            errdefer group_list.deinit();
            try std.fmt.format(group_list.writer(), "{s}", .{sudo_group});
            for (info.group.items) |group| {
                if (std.mem.eql(u8, group.name, sudo_group)) {
                    continue;
                }
                try std.fmt.format(group_list.writer(), ",{s}", .{group.name});
            }
            try useradd_argv.append(group_list.items);
            break :val try group_list.toOwnedSlice();
        } else {
            break :val null;
        }
    };
    defer if (additional_groups) |e| {
        allocator.free(e);
    };
    try useradd_argv.append(info.user);
    const add_result = try run(.{
        .allocator = allocator,
        .argv = useradd_argv.items,
    });
    allocator.free(add_result.stdout);
    defer allocator.free(add_result.stderr);
    switch (add_result.term) {
        .Exited => |code| {
            switch (code) {
                0 => return,
                9 => {
                    log.info("don't need to create user {s} with uid {s} modifying instead", .{ info.user, uid });
                },
                else => {
                    log.err("useradd exited with error code {} and message {s}", .{ code, add_result.stderr });
                    return error.UseraddFailed;
                },
            }
        },
        else => |code| {
            log.err("useradd exited unexpectedly with {}\n", .{code});
            return error.UseraddUnexpectedError;
        },
    }
    var usermod_argv = std.ArrayList([]const u8).init(allocator);
    defer usermod_argv.deinit();
    try usermod_argv.appendSlice(&[_][]const u8{
        "usermod",
        "--non-unique",
        "--home",
        info.home,
        "--uid",
        uid,
        "--shell",
        info.shell,
        "--append",
        "--groups",
    });
    if (additional_groups) |e| {
        try usermod_argv.append(e);
    }
    try usermod_argv.append(info.user);
    const mod_result = try run(.{
        .allocator = allocator,
        .argv = usermod_argv.items,
    });
    allocator.free(mod_result.stdout);
    defer allocator.free(mod_result.stderr);
    switch (mod_result.term) {
        .Exited => |code| {
            switch (code) {
                0 => return,
                else => {
                    log.err("usermod exited with error code {}\n{s}\n", .{ code, mod_result.stderr });
                    return error.UsermodFailed;
                },
            }
        },
        else => |code| {
            log.err("usermod exited unexpectedly with {}\n", .{code});
            return error.UsermodExpectedError;
        },
    }
}

var test_child_variable = if (builtin.is_test) struct {
    after: u32 = 0,
    behaviour: enum {
        Error,
        UnexpectedExit,
        FailedExit,
    } = .FailedExit,
    exit_code: u8 = 1,
}{} else @compileError("This variable should only be used to manipulate the behaviour of test_child_run during testing.");
var test_child_log = if (builtin.is_test) std.ArrayList([]const []const u8).init(std.testing.allocator) else @compileError("This variable should only be used to manipulate the behaviour of test_child_run during testing.");
fn clearTestChildLog() void {
    if (!builtin.is_test) {
        @compileError("This function is only intended for testing.");
    }
    for (test_child_log.items) |argv| {
        for (argv) |arg| {
            std.testing.allocator.free(arg);
        }
        std.testing.allocator.free(argv);
    }
    test_child_log.clearAndFree();
}

fn test_child_run(args: struct {
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    cwd_dir: ?std.fs.Dir = null,
    env_map: ?*const std.process.EnvMap = null,
    max_output_bytes: usize = 50 * 1024,
    expand_arg0: std.process.Child.Arg0Expand = .no_expand,
}) std.process.Child.RunError!std.process.Child.RunResult {
    if (!builtin.is_test) {
        @compileError("This function is only intended to be used for tests.");
    }
    const allocator = std.testing.allocator;
    std.debug.assert(args.allocator.ptr == allocator.ptr);
    var new_argv = try std.ArrayList([]const u8).initCapacity(allocator, args.argv.len);
    errdefer {
        for (new_argv.items) |arg| {
            allocator.free(arg);
        }
        new_argv.deinit();
    }
    for (args.argv) |arg| {
        const new_arg = try allocator.dupe(u8, arg);
        errdefer allocator.free(new_arg);
        try new_argv.append(new_arg);
    }
    var as_slice: ?[][]const u8 = try new_argv.toOwnedSlice();
    errdefer if (as_slice) |e| {
        new_argv = std.ArrayList([]const u8).fromOwnedSlice(allocator, e);
    };
    try test_child_log.append(as_slice.?);
    as_slice = null;
    const result = val: {
        switch (test_child_variable.after) {
            0 => switch (test_child_variable.behaviour) {
                .Error => break :val std.process.Child.RunError.AccessDenied,
                .UnexpectedExit => break :val std.process.Child.RunResult{
                    .term = .{
                        .Signal = 1,
                    },
                    .stdout = try allocator.dupe(u8, ""),
                    .stderr = try allocator.dupe(u8, ""),
                },
                .FailedExit => break :val std.process.Child.RunResult{
                    .term = .{
                        .Exited = test_child_variable.exit_code,
                    },
                    .stdout = try allocator.dupe(u8, ""),
                    .stderr = try allocator.dupe(u8, "some failure"),
                },
            },
            else => break :val std.process.Child.RunResult{
                .term = .{
                    .Exited = 0,
                },
                .stdout = try allocator.dupe(u8, ""),
                .stderr = try allocator.dupe(u8, ""),
            },
        }
    };
    const ov = @subWithOverflow(test_child_variable.after, 1);
    test_child_variable.after = if (ov[1] == 0) ov[0] else 0;
    return result;
}

fn check_groupadd_command(group: Group, command: []const []const u8) !void {
    var pos = try std.testing.allocator.alloc(bool, command.len);
    defer std.testing.allocator.free(pos);
    @memset(pos, false);

    try std.testing.expectEqualStrings("groupadd", command[0]);
    pos[0] = true;
    for (command, 0..) |c, i| {
        if (std.mem.eql(u8, c, "--non-unique")) {
            pos[i] = true;
            break;
        }
    } else {
        return error.DisallowsDuplicatedGroups;
    }
    for (command, 0..) |c, i| {
        if (std.mem.eql(u8, c, "--gid")) {
            const num = try std.fmt.allocPrint(std.testing.allocator, "{}", .{group.gid});
            defer std.testing.allocator.free(num);
            try std.testing.expectEqualStrings(num, command[i + 1]);
            pos[i] = true;
            pos[i + 1] = true;
            break;
        }
    } else {
        return error.GidNotSet;
    }
    for (pos, 0..) |p, i| {
        if (!p) {
            try std.testing.expectEqualStrings(group.name, command[i]);
            pos[i] = true;
            break;
        }
    } else {
        return error.GroupaddGroupNameMissing;
    }

    for (pos) |p| {
        if (!p) {
            return error.UnexpectedArgument;
        }
    }
}

fn check_useradd_command(info: Info, command: []const []const u8) !void {
    const sudo_group = try get_sudo_group();
    var pos = try std.testing.allocator.alloc(bool, command.len);
    defer std.testing.allocator.free(pos);
    @memset(pos, false);

    try std.testing.expectEqualStrings("useradd", command[0]);
    pos[0] = true;
    for (command, 0..) |c, i| {
        if (std.mem.eql(u8, "--home-dir", c)) {
            try std.testing.expectEqualStrings(info.home, command[i + 1]);
            pos[i] = true;
            pos[i + 1] = true;
            break;
        }
    } else {
        return error.HomedirNotSet;
    }
    for (command, 0..) |c, i| {
        if (std.mem.eql(u8, "--shell", c)) {
            try std.testing.expectEqualStrings(info.shell, command[i + 1]);
            pos[i] = true;
            pos[i + 1] = true;
            break;
        }
    } else {
        return error.ShellNotSet;
    }
    for (command, 0..) |c, i| {
        if (std.mem.eql(u8, "--uid", c)) {
            const uid = try std.fmt.allocPrint(std.testing.allocator, "{}", .{info.uid});
            defer std.testing.allocator.free(uid);
            try std.testing.expectEqualStrings(uid, command[i + 1]);
            pos[i] = true;
            pos[i + 1] = true;
            break;
        }
    } else {
        return error.UidNotSet;
    }
    for (command, 0..) |c, i| {
        if (std.mem.eql(u8, "--groups", c)) {
            var visited = try std.testing.allocator.alloc(bool, info.group.items.len);
            defer std.testing.allocator.free(visited);
            @memset(visited, false);
            outer: for (info.group.items, 0..) |group, j| {
                var iter = std.mem.tokenizeAny(u8, command[i + 1], ",");
                while (iter.next()) |gname| {
                    if (std.mem.eql(u8, gname, group.name)) {
                        visited[j] = true;
                        continue :outer;
                    }
                    if (std.mem.eql(u8, gname, sudo_group)) {
                        visited[j] = true;
                        continue :outer;
                    }
                } else {
                    return error.UseraddUnknownGroup;
                }
            }
            for (visited, 0..) |v, j| {
                if (!v) {
                    std.debug.print("missing group: {s}\n", .{if (j != 0) info.group.items[j].name else sudo_group});
                    return error.UseraddMissingGroup;
                }
            }
            pos[i] = true;
            pos[i + 1] = true;
            break;
        }
    } else {
        return error.UseraddNotSettingGroups;
    }
    for (command, 0..) |c, i| {
        if (std.mem.eql(u8, "--gid", c)) {
            try std.testing.expectEqualStrings(info.group.items[0].name, command[i + 1]);
            pos[i] = true;
            pos[i + 1] = true;
            break;
        }
    } else {
        return error.UseraddPrimaryGroupNotSet;
    }
    for (command, 0..) |c, i| {
        if (std.mem.eql(u8, "--no-create-home", c)) {
            pos[i] = true;
            break;
        }
    } else {
        return error.CreatesHome;
    }
    for (pos, 0..) |p, i| {
        if (!p) {
            try std.testing.expectEqualStrings(info.user, command[i]);
            pos[i] = true;
            break;
        }
    } else {
        return error.UseraddUserNameMissing;
    }

    for (pos) |p| {
        if (!p) {
            return error.UnexpectedArgument;
        }
    }
}

fn check_usermod_command(info: Info, command: []const []const u8) !void {
    const sudo_group = try get_sudo_group();
    var pos = try std.testing.allocator.alloc(bool, command.len);
    defer std.testing.allocator.free(pos);
    @memset(pos, false);

    try std.testing.expectEqualStrings("usermod", command[0]);
    pos[0] = true;
    for (command, 0..) |c, i| {
        if (std.mem.eql(u8, "--non-unique", c)) {
            pos[i] = true;
            break;
        }
    } else {
        return error.DisallowsDuplicatedGroups;
    }
    for (command, 0..) |c, i| {
        if (std.mem.eql(u8, "--home", c)) {
            try std.testing.expectEqualStrings(info.home, command[i + 1]);
            pos[i] = true;
            pos[i + 1] = true;
            break;
        }
    } else {
        return error.HomedirNotSet;
    }
    for (command, 0..) |c, i| {
        if (std.mem.eql(u8, "--uid", c)) {
            const uid = try std.fmt.allocPrint(std.testing.allocator, "{}", .{info.uid});
            defer std.testing.allocator.free(uid);
            try std.testing.expectEqualStrings(uid, command[i + 1]);
            pos[i] = true;
            pos[i + 1] = true;
            break;
        }
    } else {
        return error.UidNotSet;
    }
    for (command, 0..) |c, i| {
        if (std.mem.eql(u8, "--shell", c)) {
            try std.testing.expectEqualStrings(info.shell, command[i + 1]);
            pos[i] = true;
            pos[i + 1] = true;
            break;
        }
    } else {
        return error.ShellNotSet;
    }
    for (command, 0..) |c, i| {
        if (std.mem.eql(u8, "--append", c)) {
            pos[i] = true;
            break;
        }
    } else {
        return error.UsermodNotInAppendGroupsMode;
    }
    for (command, 0..) |c, i| {
        if (std.mem.eql(u8, "--groups", c)) {
            var visited = try std.testing.allocator.alloc(bool, info.group.items.len);
            defer std.testing.allocator.free(visited);
            @memset(visited, false);
            outer: for (info.group.items, 0..) |group, j| {
                var iter = std.mem.tokenizeAny(u8, command[i + 1], ",");
                while (iter.next()) |gname| {
                    if (std.mem.eql(u8, gname, group.name)) {
                        visited[j] = true;
                        continue :outer;
                    }
                    if (std.mem.eql(u8, gname, sudo_group)) {
                        visited[j] = true;
                        continue :outer;
                    }
                } else {
                    return error.UseraddUnknownGroup;
                }
            }
            for (visited, 0..) |v, j| {
                if (!v) {
                    std.debug.print("missing group: {s}\n", .{if (j != 0) info.group.items[j].name else sudo_group});
                    return error.UseraddMissingGroup;
                }
            }
            pos[i] = true;
            pos[i + 1] = true;
            break;
        }
    } else {
        return error.UseraddNotSettingGroups;
    }
    for (pos, 0..) |p, i| {
        if (!p) {
            try std.testing.expectEqualStrings(info.user, command[i]);
            pos[i] = true;
            break;
        }
    } else {
        return error.UnexpectedArgument;
    }
    for (pos) |p| {
        if (!p) {
            return error.UsermodUserNameMissing;
        }
    }
}

test "ensure_user: groupadd unexpected exit" {
    defer clearTestChildLog();
    var group_list = std.ArrayList(Group).init(std.testing.allocator);
    defer group_list.deinit();
    try group_list.appendSlice(&[_]Group{
        .{
            .gid = 5,
            .name = "video",
        },
        .{
            .gid = 10,
            .name = "hi",
        },
    });
    test_child_variable = .{
        .after = 0,
        .behaviour = .UnexpectedExit,
    };
    const info = Info{
        .group = group_list,
        .home = "/fdg/hi",
        .shell = "/bin/sh",
        .uid = 5,
        .user = "hi",
    };
    try std.testing.expectError(error.GroupaddUnexpectedError, ensure_user(std.testing.allocator, info));
    try std.testing.expectEqual(1, test_child_log.items.len);
    for (group_list.items[0..1], test_child_log.items) |group, command| {
        check_groupadd_command(group, command) catch |err| {
            for (command) |c| {
                std.debug.print("{s} ", .{c});
            }
            std.debug.print("\n", .{});
            return err;
        };
    }
}

test "ensure_user: groupadd error exit" {
    defer clearTestChildLog();
    var group_list = std.ArrayList(Group).init(std.testing.allocator);
    defer group_list.deinit();
    try group_list.appendSlice(&[_]Group{
        .{
            .gid = 5,
            .name = "video",
        },
        .{
            .gid = 10,
            .name = "hi",
        },
    });
    const info = Info{
        .group = group_list,
        .home = "/fdg/hi",
        .shell = "/bin/sh",
        .uid = 5,
        .user = "hi",
    };
    test_child_variable = .{
        .after = 1,
        .behaviour = .FailedExit,
    };
    try std.testing.expectError(error.GroupaddFailed, ensure_user(std.testing.allocator, info));
    try std.testing.expectEqual(2, test_child_log.items.len);
    for (group_list.items, test_child_log.items) |group, command| {
        check_groupadd_command(group, command) catch |err| {
            for (command) |c| {
                std.debug.print("{s} ", .{c});
            }
            std.debug.print("\n", .{});
            return err;
        };
    }
}

test "ensure_user: groupadd start failed" {
    defer clearTestChildLog();
    var group_list = std.ArrayList(Group).init(std.testing.allocator);
    defer group_list.deinit();
    try group_list.appendSlice(&[_]Group{
        .{
            .gid = 5,
            .name = "video",
        },
        .{
            .gid = 10,
            .name = "hi",
        },
    });
    const info = Info{
        .group = group_list,
        .home = "/fdg/hi",
        .shell = "/bin/sh",
        .uid = 5,
        .user = "hi",
    };
    test_child_variable = .{
        .after = 1,
        .behaviour = .Error,
    };
    try std.testing.expectError(error.AccessDenied, ensure_user(std.testing.allocator, info));
    try std.testing.expectEqual(2, test_child_log.items.len);
    for (group_list.items, test_child_log.items) |group, command| {
        check_groupadd_command(group, command) catch |err| {
            for (command) |c| {
                std.debug.print("{s} ", .{c});
            }
            std.debug.print("\n", .{});
            return err;
        };
    }
}

test "ensure_user: useradd unexpected exit" {
    defer clearTestChildLog();
    var group_list = std.ArrayList(Group).init(std.testing.allocator);
    defer group_list.deinit();
    try group_list.appendSlice(&[_]Group{
        .{
            .gid = 5,
            .name = "video",
        },
        .{
            .gid = 10,
            .name = "hi",
        },
    });
    const info = Info{
        .group = group_list,
        .home = "/fdg/hi",
        .shell = "/bin/sh",
        .uid = 5,
        .user = "hi",
    };
    test_child_variable = .{
        .after = 2,
        .behaviour = .UnexpectedExit,
    };
    try std.testing.expectError(error.UseraddUnexpectedError, ensure_user(std.testing.allocator, info));
    try std.testing.expectEqual(3, test_child_log.items.len);
    for (group_list.items, test_child_log.items[0..2]) |group, command| {
        check_groupadd_command(group, command) catch |err| {
            for (command) |c| {
                std.debug.print("{s} ", .{c});
            }
            std.debug.print("\n", .{});
            return err;
        };
    }
    check_useradd_command(info, test_child_log.items[2]) catch |err| {
        for (test_child_log.items[2]) |c| {
            std.debug.print("{s} ", .{c});
        }
        std.debug.print("\n", .{});
        return err;
    };
}

test "ensure_user: useradd error exit" {
    defer clearTestChildLog();
    var group_list = std.ArrayList(Group).init(std.testing.allocator);
    defer group_list.deinit();
    try group_list.appendSlice(&[_]Group{
        .{
            .gid = 5,
            .name = "video",
        },
        .{
            .gid = 10,
            .name = "hi",
        },
    });
    const info = Info{
        .group = group_list,
        .home = "/fdg/hi",
        .shell = "/bin/sh",
        .uid = 5,
        .user = "hi",
    };
    test_child_variable = .{
        .after = 2,
        .behaviour = .FailedExit,
    };
    try std.testing.expectError(error.UseraddFailed, ensure_user(std.testing.allocator, info));
    try std.testing.expectEqual(3, test_child_log.items.len);
    for (group_list.items, test_child_log.items[0..2]) |group, command| {
        check_groupadd_command(group, command) catch |err| {
            for (command) |c| {
                std.debug.print("{s} ", .{c});
            }
            std.debug.print("\n", .{});
            return err;
        };
    }
    check_useradd_command(info, test_child_log.items[2]) catch |err| {
        for (test_child_log.items[2]) |c| {
            std.debug.print("{s} ", .{c});
        }
        std.debug.print("\n", .{});
        return err;
    };
}

test "ensure_user: useradd started failed" {
    defer clearTestChildLog();
    var group_list = std.ArrayList(Group).init(std.testing.allocator);
    defer group_list.deinit();
    try group_list.appendSlice(&[_]Group{
        .{
            .gid = 5,
            .name = "video",
        },
        .{
            .gid = 10,
            .name = "hi",
        },
    });
    const info = Info{
        .group = group_list,
        .home = "/fdg/hi",
        .shell = "/bin/sh",
        .uid = 5,
        .user = "hi",
    };
    test_child_variable = .{
        .after = 2,
        .behaviour = .Error,
    };
    try std.testing.expectError(error.AccessDenied, ensure_user(std.testing.allocator, info));
    try std.testing.expectEqual(3, test_child_log.items.len);
    for (group_list.items, test_child_log.items[0..2]) |group, command| {
        check_groupadd_command(group, command) catch |err| {
            for (command) |c| {
                std.debug.print("{s} ", .{c});
            }
            std.debug.print("\n", .{});
            return err;
        };
    }
    check_useradd_command(info, test_child_log.items[2]) catch |err| {
        for (test_child_log.items[2]) |c| {
            std.debug.print("{s} ", .{c});
        }
        std.debug.print("\n", .{});
        return err;
    };
}

test "ensure_user: useradd user already exists" {
    defer clearTestChildLog();
    var group_list = std.ArrayList(Group).init(std.testing.allocator);
    defer group_list.deinit();
    try group_list.appendSlice(&[_]Group{
        .{
            .gid = 5,
            .name = "video",
        },
        .{
            .gid = 10,
            .name = "hi",
        },
    });
    const info = Info{
        .group = group_list,
        .home = "/fdg/hi",
        .shell = "/bin/sh",
        .uid = 5,
        .user = "hi",
    };
    test_child_variable = .{
        .after = 2,
        .behaviour = .FailedExit,
        .exit_code = 9,
    };
    try std.testing.expectError(error.UsermodFailed, ensure_user(std.testing.allocator, info));
    try std.testing.expectEqual(4, test_child_log.items.len);
    for (group_list.items, test_child_log.items[0..2]) |group, command| {
        check_groupadd_command(group, command) catch |err| {
            for (command) |c| {
                std.debug.print("{s} ", .{c});
            }
            std.debug.print("\n", .{});
            return err;
        };
    }
    check_useradd_command(info, test_child_log.items[2]) catch |err| {
        for (test_child_log.items[2]) |c| {
            std.debug.print("{s} ", .{c});
        }
        std.debug.print("\n", .{});
        return err;
    };
}

test "ensure_user: useradd success" {
    defer clearTestChildLog();
    var group_list = std.ArrayList(Group).init(std.testing.allocator);
    defer group_list.deinit();
    try group_list.appendSlice(&[_]Group{
        .{
            .gid = 5,
            .name = "video",
        },
        .{
            .gid = 10,
            .name = "hi",
        },
    });
    const info = Info{
        .group = group_list,
        .home = "/fdg/hi",
        .shell = "/bin/sh",
        .uid = 5,
        .user = "hi",
    };
    test_child_variable = .{
        .after = 4,
        .behaviour = .FailedExit,
        .exit_code = 9,
    };
    try ensure_user(std.testing.allocator, info);
    try std.testing.expectEqual(3, test_child_log.items.len);
    for (group_list.items, test_child_log.items[0..2]) |group, command| {
        check_groupadd_command(group, command) catch |err| {
            for (command) |c| {
                std.debug.print("{s} ", .{c});
            }
            std.debug.print("\n", .{});
            return err;
        };
    }
    check_useradd_command(info, test_child_log.items[2]) catch |err| {
        for (test_child_log.items[2]) |c| {
            std.debug.print("{s} ", .{c});
        }
        std.debug.print("\n", .{});
        return err;
    };
}

test "ensure_user: usermod" {
    defer clearTestChildLog();
    var group_list = std.ArrayList(Group).init(std.testing.allocator);
    defer group_list.deinit();
    try group_list.appendSlice(&[_]Group{
        .{
            .gid = 5,
            .name = "video",
        },
        .{
            .gid = 10,
            .name = "hi",
        },
    });
    const info = Info{
        .group = group_list,
        .home = "/fdg/hi",
        .shell = "/bin/sh",
        .uid = 5,
        .user = "hi",
    };
    test_child_variable = .{
        .after = 2,
        .behaviour = .FailedExit,
        .exit_code = 9,
    };
    try std.testing.expectError(error.UsermodFailed, ensure_user(std.testing.allocator, info));
    try std.testing.expectEqual(4, test_child_log.items.len);
    for (group_list.items, test_child_log.items[0..2]) |group, command| {
        check_groupadd_command(group, command) catch |err| {
            for (command) |c| {
                std.debug.print("{s} ", .{c});
            }
            std.debug.print("\n", .{});
            return err;
        };
    }
    check_useradd_command(info, test_child_log.items[2]) catch |err| {
        for (test_child_log.items[2]) |c| {
            std.debug.print("{s} ", .{c});
        }
        std.debug.print("\n", .{});
        return err;
    };
    check_usermod_command(info, test_child_log.items[3]) catch |err| {
        for (test_child_log.items[3]) |c| {
            std.debug.print("{s} ", .{c});
        }
        std.debug.print("\n", .{});
        return err;
    };
}
