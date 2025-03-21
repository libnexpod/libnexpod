const std = @import("std");
const utils = @import("utils");
const container = @import("container.zig");

const libnexpodd_default_path = "/usr/libexec/libnexpod/libnexpodd";

pub fn getEntrypointArgv(arena_allocator: std.mem.Allocator, home: []const u8) ![]const []const u8 {
    const base = "/usr/libexec/libnexpod/libnexpodd";

    var result = std.ArrayListUnmanaged([]const u8).empty;

    try result.append(arena_allocator, base);

    try result.append(arena_allocator, "--uid");
    const uid = std.os.linux.getuid();
    try result.append(arena_allocator, try std.fmt.allocPrint(arena_allocator, "{}", .{uid}));

    const name, const primary_gid, const shell = try getNamePrimaryGroupAndShellFromPasswd(arena_allocator, uid);

    try result.append(arena_allocator, "--user");
    try result.append(arena_allocator, name);

    try result.append(arena_allocator, "--shell");
    try result.append(arena_allocator, shell);

    try result.append(arena_allocator, "--home");
    try result.append(arena_allocator, home);

    const primary_group_name, const groups = try getGroupsWithMember(arena_allocator, name, primary_gid);

    try result.append(arena_allocator, "--group");
    try result.append(arena_allocator, try std.fmt.allocPrint(arena_allocator, "{}={s}", .{ primary_gid, primary_group_name }));

    var group_iter = groups.iterator();
    while (group_iter.next()) |entry| {
        try result.append(arena_allocator, "--group");
        try result.append(arena_allocator, try std.fmt.allocPrint(arena_allocator, "{}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }));
    }

    return try result.toOwnedSlice(arena_allocator);
}

fn getGroupsWithMember(allocator: std.mem.Allocator, user: []const u8, primary_group: std.posix.gid_t) !struct { []const u8, std.AutoHashMap(std.posix.gid_t, []const u8) } {
    var file = try std.fs.openFileAbsolute("/etc/group", .{});
    defer file.close();
    var bufferedReader = std.io.bufferedReader(file.reader());
    var reader = bufferedReader.reader();

    var result = std.AutoHashMap(std.posix.gid_t, []const u8).init(allocator);
    errdefer {
        var iter = result.valueIterator();
        while (iter.next()) |e| {
            allocator.free(e.*);
        }
        result.deinit();
    }

    var primary_group_name: ?[]const u8 = null;
    errdefer if (primary_group_name) |pgn| {
        allocator.free(pgn);
    };
    var buffer = std.ArrayListUnmanaged(u8).empty;
    defer buffer.deinit(allocator);
    while (true) {
        reader.streamUntilDelimiter(buffer.writer(allocator), '\n', null) catch |err| switch (err) {
            error.EndOfStream => break,
            else => |rest| return rest,
        };
        defer buffer.clearRetainingCapacity();

        if (std.mem.eql(u8, "", buffer.items)) {
            break;
        }

        var column_iterator = std.mem.splitScalar(u8, buffer.items, ':');
        const name = column_iterator.next() orelse return error.InvalidFileFormat;
        // skip over password/x
        _ = column_iterator.next();
        const str_gid = column_iterator.next() orelse return error.InvalidFileFormat;
        const gid = try std.fmt.parseInt(std.posix.gid_t, str_gid, 10);
        if (gid == primary_group) {
            primary_group_name = try allocator.dupe(u8, name);
            continue;
        }
        const user_list = column_iterator.next() orelse return error.InvalidFileFormat;

        var user_iter = std.mem.tokenizeScalar(u8, user_list, ',');
        while (user_iter.next()) |username| {
            if (std.mem.eql(u8, user, username)) {
                const name_dupe = try allocator.dupe(u8, name);
                errdefer allocator.free(name_dupe);
                try result.put(gid, name_dupe);
                break;
            }
        }
    }

    if (primary_group_name) |pgn| {
        return .{ pgn, result };
    } else {
        return error.PrimaryGroupnameNotFound;
    }
}

fn getNamePrimaryGroupAndShellFromPasswd(allocator: std.mem.Allocator, uid: std.posix.uid_t) !struct { []const u8, std.posix.gid_t, []const u8 } {
    var file = try std.fs.openFileAbsolute("/etc/passwd", .{});
    defer file.close();
    var bufferedReader = std.io.bufferedReader(file.reader());
    var reader = bufferedReader.reader();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    while (true) {
        try reader.streamUntilDelimiter(buffer.writer(), '\n', null);
        defer buffer.clearRetainingCapacity();

        if (std.mem.eql(u8, "", buffer.items)) {
            return error.UsernameNotFound;
        }

        var iter = std.mem.splitScalar(u8, buffer.items, ':');
        const name = iter.next() orelse return error.InvalidFileFormat;
        // skip over password/x
        _ = iter.next();
        const str_uid = iter.next() orelse return error.InvalidFileFormat;
        if (try std.fmt.parseInt(std.posix.uid_t, str_uid, 10) == uid) {
            const name_dupe = try allocator.dupe(u8, name);
            errdefer allocator.free(name_dupe);
            const str_gid = iter.next() orelse return error.InvalidFileFormat;
            const gid = try std.fmt.parseInt(std.posix.gid_t, str_gid, 10);
            // skip over GECOS and HOME
            _ = iter.next();
            _ = iter.next();
            const shell = iter.next() orelse return error.InvalidFileFormat;
            const shell_dupe = try allocator.dupe(u8, shell);
            errdefer allocator.free(shell_dupe);

            return .{ name_dupe, gid, shell_dupe };
        }
    }
    return error.UsernameNotFound;
}

test getNamePrimaryGroupAndShellFromPasswd {
    const name, const group, const shell = try getNamePrimaryGroupAndShellFromPasswd(std.testing.allocator, 1000);
    std.debug.print("name:  {s}\ngroup: {}\nshell: {s}\n", .{ name, group, shell });
    std.testing.allocator.free(name);
    std.testing.allocator.free(shell);
}

pub fn getMounts(allocator: std.mem.Allocator, additional_mounts: []const container.Mount, env: std.process.EnvMap, home: []const u8, libnexpodd_path: ?[]const u8) ![]container.Mount {
    var mounts = try std.ArrayListUnmanaged(container.Mount).initCapacity(allocator, additional_mounts.len);
    errdefer {
        for (mounts.items) |e| {
            allocator.free(e.source);
            allocator.free(e.destination);
            if (e.kind == .volume) {
                allocator.free(e.kind.volume.name);
            }
        }
        mounts.deinit(allocator);
    }

    for (additional_mounts) |e| {
        const source = try allocator.dupe(u8, e.source);
        errdefer allocator.free(source);
        const destination = try allocator.dupe(u8, e.source);
        errdefer allocator.free(destination);
        mounts.appendAssumeCapacity(.{
            .source = source,
            .destination = destination,
            .kind = switch (e.kind) {
                .volume => |v| .{ .volume = .{ .name = try allocator.dupe(u8, v.name) } },
                .bind => |b| .{ .bind = b },
                .devpts => |d| .{ .devpts = d },
            },
            .propagation = e.propagation,
            .options = e.options,
        });
    }

    try appendStaticMounts(allocator, &mounts);

    try appendSystemBus(allocator, &mounts, env);

    try appendHome(allocator, &mounts, home);

    try appendRuntimeDir(allocator, &mounts, env);

    for (&[_][]const u8{
        "KCM",
        "PCSC",
        "Avahi",
    }) |service| {
        if (try getServiceSocket(service)) |path| {
            const path1 = try allocator.dupe(u8, path);
            errdefer allocator.free(path1);
            const path2 = try allocator.dupe(u8, path);
            errdefer allocator.free(path2);
            try mounts.append(allocator, .{
                .source = path1,
                .destination = path2,
                .kind = .{ .bind = .{} },
                .options = .{ .rw = true, .exec = false },
                .propagation = .none,
            });
        }
    }

    {
        const source = try allocator.dupe(u8, libnexpodd_path orelse libnexpodd_default_path);
        errdefer allocator.free(source);
        const destination = try allocator.dupe(u8, libnexpodd_default_path);
        errdefer allocator.free(destination);
        try mounts.append(allocator, .{
            .source = source,
            .destination = destination,
            .kind = .{ .bind = .{} },
            .options = .{ .rw = false },
            .propagation = .none,
        });
    }

    return try mounts.toOwnedSlice(allocator);
}

fn getServiceSocket(service: []const u8) error{ServiceNotYetSupported}!?[]const u8 {
    //TODO: ask systemd
    const path = val: {
        if (std.mem.eql(u8, "KCM", service)) {
            break :val "/run/.heim_org.h5l.kcm-socket";
        } else if (std.mem.eql(u8, "PCSC", service)) {
            break :val "/run/pcscd/pcscd.comm";
        } else if (std.mem.eql(u8, "Avahi", service)) {
            break :val "/run/avahi-daemon/socket";
        } else {
            return error.ServiceNotYetSupported;
        }
    };
    return if (utils.fileExists(path)) path else null;
}

fn appendRuntimeDir(allocator: std.mem.Allocator, mounts: *std.ArrayListUnmanaged(container.Mount), env: std.process.EnvMap) !void {
    const dir = if (env.get("XDG_RUNTIME_DIR")) |dir|
        try allocator.dupe(u8, dir)
    else if (std.os.linux.getuid() == 0)
        try allocator.dupe(u8, "/run/libnexpod")
    else
        return error.NoRuntimeDirFound;
    errdefer allocator.free(dir);
    const dir_dupe = try allocator.dupe(u8, dir);
    errdefer allocator.free(dir_dupe);
    try mounts.append(allocator, .{
        .source = dir,
        .destination = dir_dupe,
        .kind = .{ .bind = .{ .recursive = true } },
        .options = .{ .rw = true },
        .propagation = .rshared,
    });
}

fn appendHome(allocator: std.mem.Allocator, mounts: *std.ArrayListUnmanaged(container.Mount), home: []const u8) !void {
    const home1 = try allocator.dupe(u8, home);
    errdefer allocator.free(home1);
    const home2 = try allocator.dupe(u8, home);
    errdefer allocator.free(home2);
    try mounts.append(allocator, .{
        .source = home1,
        .destination = home2,
        .kind = .{ .bind = .{ .recursive = false } },
        .propagation = .rshared,
        .options = .{
            .rw = true,
            .suid = true,
        },
    });
}

fn appendSystemBus(allocator: std.mem.Allocator, mounts: *std.ArrayListUnmanaged(container.Mount), env: std.process.EnvMap) !void {
    const default_system_bus_path = "/var/run/dbus/system_bus_socket";
    const system_bus = if (env.get("DBUS_SYSTEM_BUS_ADDRESS")) |path|
        if (std.mem.indexOf(u8, path, "=")) |index| b: {
            break :b path[index + 1 .. path.len];
        } else {
            return error.InvalidValueInEnvironment;
        }
    else
        try allocator.dupe(u8, default_system_bus_path);
    errdefer allocator.free(system_bus);
    const system_bus_clone = try allocator.dupe(u8, system_bus);
    errdefer allocator.free(system_bus_clone);
    try mounts.append(allocator, .{
        .source = system_bus,
        .destination = system_bus_clone,
        .kind = .{ .bind = .{ .recursive = false } },
        .propagation = .rprivate,
        .options = .{
            .rw = true,
            .exec = false,
        },
    });
}

fn appendStaticMounts(allocator: std.mem.Allocator, mounts: *std.ArrayListUnmanaged(container.Mount)) !void {
    for (&[_]container.Mount{
        container.Mount{
            .source = "/etc/resolv.conf",
            .destination = "/etc/resolv.conf",
            .kind = .{ .bind = .{} },
            .options = .{ .rw = false, .exec = false },
            .propagation = .none,
        },
        container.Mount{
            .source = "/etc/hosts",
            .destination = "/etc/hosts",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = false, .exec = false },
            .propagation = .none,
        },
        container.Mount{
            .source = "/etc/host.conf",
            .destination = "/etc/host.conf",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = false, .exec = false },
            .propagation = .none,
        },
        container.Mount{
            .source = "/etc/hostname",
            .destination = "/etc/hostname",
            .kind = .{ .bind = .{} },
            .options = .{ .rw = false, .exec = false },
            .propagation = .none,
        },
        container.Mount{
            .source = "/etc/machine-id",
            .destination = "/etc/machine-id",
            .kind = .{ .bind = .{} },
            .options = .{ .rw = false, .exec = true },
            .propagation = .none,
        },
        container.Mount{
            .source = "/",
            .destination = "/run/host/",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        container.Mount{
            .source = "/tmp",
            .destination = "/tmp",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{
                .rw = true,
                .exec = false,
            },
            .propagation = .rslave,
        },
        container.Mount{
            .source = "/dev",
            .destination = "/dev",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true, .dev = true },
            .propagation = .rslave,
        },
        container.Mount{
            .source = "/sys",
            .destination = "/sys",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true, .exec = false },
            .propagation = .rslave,
        },
        container.Mount{
            .source = "/var/log/journal",
            .destination = "/var/log/journal",
            .kind = .{ .bind = .{} },
            .options = .{ .rw = true, .exec = false },
            .propagation = .none,
        },
        container.Mount{
            .source = "/var/lib/flatpak",
            .destination = "/var/lib/flatpak",
            .kind = .{ .bind = .{} },
            .options = .{ .rw = true },
            .propagation = .rprivate,
        },
        container.Mount{
            .source = "/var/lib/libvirt",
            .destination = "/var/lib/libvirt",
            .kind = .{ .bind = .{} },
            .options = .{ .rw = true },
            .propagation = .rprivate,
        },
        container.Mount{
            .source = "/var/lib/systemd/coredump",
            .destination = "/var/lib/systemd/coredump",
            .kind = .{ .bind = .{} },
            .options = .{ .rw = true },
            .propagation = .rprivate,
        },
        container.Mount{
            .source = "/mnt",
            .destination = "/mnt",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        container.Mount{
            .source = "/var/mnt",
            .destination = "/var/mnt",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        container.Mount{
            .source = "/opt",
            .destination = "/opt",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        container.Mount{
            .source = "/var/opt",
            .destination = "/var/opt",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        container.Mount{
            .source = "/srv",
            .destination = "/srv",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        container.Mount{
            .source = "/var/srv",
            .destination = "/var/srv",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        container.Mount{
            .source = "/home",
            .destination = "/home",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        container.Mount{
            .source = "/var/home",
            .destination = "/var/home",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        container.Mount{
            .source = "/run/systemd/journal",
            .destination = "/run/systemd/journal",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        container.Mount{
            .source = "/run/systemd/resolve",
            .destination = "/run/systemd/resolve",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        container.Mount{
            .source = "/run/systemd/sessions",
            .destination = "/run/systemd/sessions",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        container.Mount{
            .source = "/run/systemd/system",
            .destination = "/run/systemd/system",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        container.Mount{
            .source = "/run/systemd/users",
            .destination = "/run/systemd/users",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        container.Mount{
            .source = "/run/media",
            .destination = "/run/media",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        container.Mount{
            .source = "/media",
            .destination = "/media",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        container.Mount{
            .source = "/run/udev",
            .destination = "/run/udev",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        container.Mount{
            .source = "",
            .destination = "/dev/pts",
            .kind = .{ .devpts = .{} },
            .options = .{ .rw = true },
            .propagation = .none,
        },
    }) |m| {
        if (!std.mem.eql(u8, m.source, "") and utils.fileExists(m.source)) {
            const source = try allocator.dupe(u8, m.source);
            errdefer allocator.free(source);
            const destination = try allocator.dupe(u8, m.destination);
            errdefer allocator.free(destination);
            const kind: @TypeOf(m.kind) = switch (m.kind) {
                .volume => |v| .{ .volume = .{ .name = try allocator.dupe(u8, v.name) } },
                .bind => |b| .{ .bind = b },
                .devpts => |d| .{ .devpts = d },
            };
            errdefer switch (kind) {
                .volume => |v| allocator.free(v.name),
                .bind => |_| {},
                .devpts => |_| {},
            };
            try mounts.append(allocator, .{
                .source = source,
                .destination = destination,
                .kind = kind,
                .propagation = m.propagation,
                .options = m.options,
            });
        }
    }
}

pub fn getHome(env: *std.process.EnvMap, home: ?[]const u8) std.mem.Allocator.Error![]const u8 {
    return if (home) |h| b: {
        try env.put("HOME", h);
        break :b h;
    } else env.get("HOME").?;
}

test getHome {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();

    const path = "/home";
    try env.put("HOME", path);

    try std.testing.expectEqualStrings(try getHome(&env, null), path);

    const overwrite = "/home/test";
    try std.testing.expectEqualStrings(try getHome(&env, overwrite), overwrite);
    try std.testing.expectEqualStrings(env.get("HOME").?, overwrite);
}

pub fn getEnvMap(allocator: std.mem.Allocator, env: ?std.process.EnvMap) (error{NeededEnvironmentVariableNotFound} || std.mem.Allocator.Error)!std.process.EnvMap {
    var original_env = if (env) |e| b: {
        var new = std.process.EnvMap.init(allocator);
        errdefer new.deinit();
        var iter = e.iterator();
        while (iter.next()) |next| {
            try new.put(next.key_ptr.*, next.value_ptr.*);
        }
        break :b new;
    } else std.process.getEnvMap(allocator) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.Unexpected => unreachable,
    };
    defer original_env.deinit();

    var result = std.process.EnvMap.init(allocator);
    errdefer result.deinit();

    const wanted_variables = [_][]const u8{
        "XDG_RUNTIME_DIR",
        "HOME",
    };
    for (wanted_variables) |key| {
        if (original_env.get(key)) |value| {
            try result.put(key, value);
        } else {
            return error.NeededEnvironmentVariableNotFound;
        }
    }

    return result;
}

test getEnvMap {
    const fail1 = std.process.EnvMap.init(std.testing.allocator);
    defer fail1.deinit();

    try fail1.put("a", "b");

    try std.testing.expectError(error.NeededEnvironmentVariableNotFound, getEnvMap(std.testing.allocator, fail1));

    const fail2 = std.process.EnvMap.init(std.testing.allocator);
    defer fail2.deinit();

    try fail2.put("a", "b");
    try fail2.put("HOME", "/home/hey");

    try std.testing.expectError(error.NeededEnvironmentVariableNotFound, getEnvMap(std.testing.allocator, fail2));

    const fail3 = std.process.EnvMap.init(std.testing.allocator);
    defer fail3.deinit();

    try fail3.put("a", "b");
    try fail3.put("XDG_RUNTIME_DIR", "/tmp");

    try std.testing.expectError(error.NeededEnvironmentVariableNotFound, getEnvMap(std.testing.allocator, fail3));

    var correct = std.process.EnvMap.init(std.testing.allocator);
    defer correct.deinit();

    try correct.put("a", "b");
    try correct.put("HOME", "/home/hey");
    try correct.put("XDG_RUNTIME_DIR", "/tmp");

    const result = try getEnvMap(std.testing.allocator, correct);
    defer result.deinit();

    try std.testing.expectEqual(2, result.count());
    var iter = result.iterator();
    while (iter.next()) |next| {
        if (correct.get(next.key_value)) |expected| {
            try std.testing.expectEqualStrings(expected, next.value_ptr);
        } else {
            return error.TestExpectedValue;
        }
    }
}
