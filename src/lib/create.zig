const std = @import("std");
const log = @import("logging");
const utils = @import("utils");
const errors = @import("errors.zig");
const podman = @import("podman.zig");
const Image = @import("image.zig").Image;
const Container = @import("container.zig").Container;
const Mount = @import("container.zig").Mount;

const nexpodd_default_path = "/usr/libexec/nexpod/nexpodd";

pub fn createContainer(allocator: std.mem.Allocator, args: struct {
    key: []const u8,
    name: []const u8,
    image: Image,
    env: ?std.process.EnvMap = null,
    additional_mounts: []const Mount,
    home_dir: ?[]const u8,
    nexpodd_path: ?[]const u8 = null,
}) errors.CreationErrors!Container {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const original_env = args.env orelse try std.process.getEnvMap(arena_allocator);
    const env = try filter_env(arena_allocator, original_env);

    const container_name = val: {
        if (std.mem.eql(u8, "", args.key)) {
            break :val args.name;
        } else {
            break :val try std.mem.concat(arena_allocator, u8, &[_][]const u8{ args.key, "-", args.name });
        }
    };

    const home_path = try getHomeDir(arena_allocator, args.home_dir, original_env);

    var mounts = std.ArrayList(Mount).init(arena_allocator);
    try mounts.appendSlice(args.additional_mounts);
    collectMounts(&mounts, original_env, args.nexpodd_path, home_path) catch |err| switch (err) {
        error.ServiceNotYetSupported => {
            @panic("Accidentally tried to find a service which isn't yet supported by this library. This is an internal error.");
        },
        else => |rest| return rest,
    };

    const entrypoint_argv = try getEntrypointArgv(arena_allocator, home_path);

    const id = try podman.createContainer(.{
        .allocator = arena_allocator,
        .env = env,
        .key = args.key,
        .name = container_name,
        .image = args.image,
        .entrypoint_argv = entrypoint_argv,
        .mounts = mounts.items,
    });

    const container_json = try podman.getContainerJSON(arena_allocator, id);
    const parsed = try std.json.parseFromSliceLeaky(Container, arena_allocator, container_json, .{});

    return try parsed.copy(allocator);
}

fn getEntrypointArgv(arena_allocator: std.mem.Allocator, home: []const u8) errors.CreationErrors![]const []const u8 {
    const base = "/usr/libexec/nexpod/nexpodd";
    var result = std.ArrayList([]const u8).init(arena_allocator);
    try result.append(base);

    try result.append("--uid");
    const uid = std.os.linux.getuid();
    try result.append(try std.fmt.allocPrint(arena_allocator, "{}", .{uid}));

    const name, const primary_gid, const shell = try getNamePrimaryGroupAndShellFromPasswd(arena_allocator, uid);

    try result.append("--user");
    try result.append(name);

    try result.append("--shell");
    try result.append(shell);

    try result.append("--home");
    try result.append(home);

    const primary_group_name, const groups = try getGroupsWithMember(arena_allocator, name, primary_gid);

    try result.append("--group");
    try result.append(try std.fmt.allocPrint(arena_allocator, "{}={s}", .{ primary_gid, primary_group_name }));

    var group_iter = groups.iterator();
    while (group_iter.next()) |entry| {
        try result.append("--group");
        try result.append(try std.fmt.allocPrint(arena_allocator, "{}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }));
    }

    return try result.toOwnedSlice();
}

fn getGroupsWithMember(allocator: std.mem.Allocator, user: []const u8, primary_group: std.posix.gid_t) errors.CreationErrors!struct { []const u8, std.AutoHashMap(std.posix.gid_t, []const u8) } {
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
    var buffer = std.ArrayList(u8).init(allocator);
    buffer.deinit();
    while (true) {
        reader.streamUntilDelimiter(buffer.writer(), '\n', null) catch |err| switch (err) {
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

fn getNamePrimaryGroupAndShellFromPasswd(allocator: std.mem.Allocator, uid: std.posix.uid_t) errors.CreationErrors!struct { []const u8, std.posix.gid_t, []const u8 } {
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

fn collectMounts(mounts: *std.ArrayList(Mount), env: std.process.EnvMap, nexpodd_path: ?[]const u8, home_path: []const u8) (error{ InvalidValueInEnvironment, NoRuntimeDirFound, ServiceNotYetSupported } || std.mem.Allocator.Error)!void {
    const static_default_mounts = [_]Mount{
        Mount{
            .source = "/etc/resolv.conf",
            .destination = "/etc/resolv.conf",
            .kind = .{ .bind = .{} },
            .options = .{ .rw = false, .exec = false },
            .propagation = .none,
        },
        Mount{
            .source = "/etc/hosts",
            .destination = "/etc/hosts",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = false, .exec = false },
            .propagation = .none,
        },
        Mount{
            .source = "/etc/host.conf",
            .destination = "/etc/host.conf",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = false, .exec = false },
            .propagation = .none,
        },
        Mount{
            .source = "/etc/hostname",
            .destination = "/etc/hostname",
            .kind = .{ .bind = .{} },
            .options = .{ .rw = false, .exec = false },
            .propagation = .none,
        },
        Mount{
            .source = "/etc/machine-id",
            .destination = "/etc/machine-id",
            .kind = .{ .bind = .{} },
            .options = .{ .rw = false, .exec = true },
            .propagation = .none,
        },
        Mount{
            .source = "/",
            .destination = "/run/host/",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        Mount{
            .source = "/tmp",
            .destination = "/tmp",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{
                .rw = true,
                .exec = false,
            },
            .propagation = .rslave,
        },
        Mount{
            .source = "/dev",
            .destination = "/dev",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true, .dev = true },
            .propagation = .rslave,
        },
        Mount{
            .source = "/sys",
            .destination = "/sys",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true, .exec = false },
            .propagation = .rslave,
        },
        Mount{
            .source = "/var/log/journal",
            .destination = "/var/log/journal",
            .kind = .{ .bind = .{} },
            .options = .{ .rw = true, .exec = false },
            .propagation = .none,
        },
        Mount{
            .source = "/var/lib/flatpak",
            .destination = "/var/lib/flatpak",
            .kind = .{ .bind = .{} },
            .options = .{ .rw = true },
            .propagation = .rprivate,
        },
        Mount{
            .source = "/var/lib/libvirt",
            .destination = "/var/lib/libvirt",
            .kind = .{ .bind = .{} },
            .options = .{ .rw = true },
            .propagation = .rprivate,
        },
        Mount{
            .source = "/var/lib/systemd/coredump",
            .destination = "/var/lib/systemd/coredump",
            .kind = .{ .bind = .{} },
            .options = .{ .rw = true },
            .propagation = .rprivate,
        },
        Mount{
            .source = "/mnt",
            .destination = "/mnt",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        Mount{
            .source = "/var/mnt",
            .destination = "/var/mnt",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        Mount{
            .source = "/opt",
            .destination = "/opt",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        Mount{
            .source = "/var/opt",
            .destination = "/var/opt",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        Mount{
            .source = "/srv",
            .destination = "/srv",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        Mount{
            .source = "/var/srv",
            .destination = "/var/srv",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        Mount{
            .source = "/home",
            .destination = "/home",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        Mount{
            .source = "/var/home",
            .destination = "/var/home",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        Mount{
            .source = "/run/systemd/journal",
            .destination = "/run/systemd/journal",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        Mount{
            .source = "/run/systemd/resolve",
            .destination = "/run/systemd/resolve",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        Mount{
            .source = "/run/systemd/sessions",
            .destination = "/run/systemd/sessions",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        Mount{
            .source = "/run/systemd/system",
            .destination = "/run/systemd/system",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        Mount{
            .source = "/run/systemd/users",
            .destination = "/run/systemd/users",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        Mount{
            .source = "/run/media",
            .destination = "/run/media",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        Mount{
            .source = "/media",
            .destination = "/media",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        Mount{
            .source = "/run/udev",
            .destination = "/run/udev",
            .kind = .{ .bind = .{ .recursive = true } },
            .options = .{ .rw = true },
            .propagation = .rslave,
        },
        Mount{
            .source = "",
            .destination = "/dev/pts",
            .kind = .{ .devpts = .{} },
            .options = .{ .rw = true },
            .propagation = .none,
        },
    };

    for (static_default_mounts) |mount| {
        if (!std.mem.eql(u8, "", mount.source) and utils.fileExists(mount.source)) {
            try mounts.*.append(mount);
        }
    }

    const dbus_system_path = val: {
        if (env.get("DBUS_SYSTEM_BUS_ADDRESS")) |path| {
            const index = std.mem.indexOf(u8, path, "=");
            if (index) |i| {
                break :val path[i + 1 .. path.len];
            } else {
                log.err("DBUS_SYSTEM_BUS_ADDRESS does not container a valid value\n", .{});
                return error.InvalidValueInEnvironment;
            }
        } else {
            break :val "/var/run/dbus/system_bus_socket";
        }
    };
    try mounts.*.append(Mount{
        .source = dbus_system_path,
        .destination = dbus_system_path,
        .kind = .{ .bind = .{ .recursive = false } },
        .options = .{ .rw = true, .exec = false },
        .propagation = .rprivate,
    });

    try mounts.*.append(Mount{
        .source = home_path,
        .destination = home_path,
        .kind = .{ .bind = .{ .recursive = true } },
        .options = .{ .rw = true, .suid = true },
        .propagation = .rshared,
    });

    const runtime_dir = try getRuntimeDir(env);
    try mounts.*.append(Mount{
        .source = runtime_dir,
        .destination = runtime_dir,
        .kind = .{ .bind = .{ .recursive = true } },
        .options = .{ .rw = true },
        .propagation = .rshared,
    });

    const kcm_socket = try getServiceSocket("KCM");
    if (kcm_socket) |socket| {
        try mounts.*.append(Mount{
            .source = socket,
            .destination = socket,
            .kind = .{ .bind = .{} },
            .options = .{ .rw = true, .exec = false },
            .propagation = .none,
        });
    }

    const pcsd_socket = try getServiceSocket("PCSC");
    if (pcsd_socket) |socket| {
        try mounts.*.append(Mount{
            .source = socket,
            .destination = socket,
            .kind = .{ .bind = .{} },
            .options = .{ .rw = true, .exec = false },
            .propagation = .none,
        });
    }

    const avahi_socket = try getServiceSocket("Avahi");
    if (avahi_socket) |socket| {
        try mounts.*.append(Mount{
            .source = socket,
            .destination = socket,
            .kind = .{ .bind = .{} },
            .options = .{ .rw = true, .exec = false },
            .propagation = .none,
        });
    }

    // nexpod stuff
    try mounts.*.append(Mount{
        .source = nexpodd_path orelse nexpodd_default_path,
        .destination = nexpodd_default_path,
        .kind = .{ .bind = .{} },
        .options = .{ .rw = false },
        .propagation = .none,
    });
}

fn getHomeDir(arena_allocator: std.mem.Allocator, home_dir: ?[]const u8, env: std.process.EnvMap) (error{NoHomeFound} || std.mem.Allocator.Error || std.posix.ReadLinkError)![]const u8 {
    var home_path = val: {
        if (home_dir) |home| {
            break :val home;
        } else if (env.get("HOME")) |home| {
            break :val home;
        } else {
            return error.NoHomeFound;
        }
    };
    var buffer = [_]u8{0} ** std.fs.max_path_bytes;
    home_path = std.fs.readLinkAbsolute(home_path, &buffer) catch |err| switch (err) {
        error.NotLink => home_path,
        else => |rest| return rest,
    };
    return try arena_allocator.dupe(u8, home_path);
}

fn getRuntimeDir(env: std.process.EnvMap) error{NoRuntimeDirFound}![]const u8 {
    if (std.os.linux.getuid() == 0) {
        return "/run/libnexpod";
    } else if (env.get("XDG_RUNTIME_DIR")) |runtime_dir| {
        return runtime_dir;
    } else {
        return error.NoRuntimeDirFound;
    }
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

fn filter_env(allocator: std.mem.Allocator, original_env: std.process.EnvMap) (error{NeededEnvironmentVariableNotFound} || std.mem.Allocator.Error)!std.process.EnvMap {
    const wanted_variables = [_][]const u8{
        "XDG_RUNTIME_DIR",
        "HOME",
    };

    var result = std.process.EnvMap.init(allocator);
    errdefer result.deinit();

    for (wanted_variables) |key| {
        if (original_env.get(key)) |value| {
            try result.put(key, value);
        } else {
            return error.NeededEnvironmentVariableNotFound;
        }
    }

    return result;
}
