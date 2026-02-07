const std = @import("std");
const zeit = @import("zeit");
const utils = @import("utils");
const log = @import("logging");
const errors = @import("errors.zig");
const image = @import("image.zig");
const container = @import("container.zig");
const Image = image.Image;
const Container = container.Container;

const label = "com.github.libnexpod";

pub fn createRunArgs(gpa: std.mem.Allocator, args: struct {
    id: []const u8,
    command: []const []const u8,
    ttyNeeded: bool,
    env: std.process.EnvMap,
    work_dir: []const u8,
    username: []const u8,
}) std.mem.Allocator.Error![]const []const u8 {
    var result: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (result.items) |e| {
            gpa.free(e);
        }
        result.deinit(gpa);
    }

    for ([_][]const u8{
        "podman",
        "container",
        "exec",
        "--interactive",
    }) |e| {
        try utils.appendClone(gpa, &result, e);
    }

    try utils.appendClone(gpa, &result, "--workdir");
    try utils.appendClone(gpa, &result, args.work_dir);
    try utils.appendClone(gpa, &result, "--user");
    try utils.appendClone(gpa, &result, args.username);

    if (args.ttyNeeded) {
        try utils.appendClone(gpa, &result, "--tty");
    }

    var iter = args.env.iterator();
    while (iter.next()) |entry| {
        try utils.appendClone(gpa, &result, "--env");
        const arg = try std.fmt.allocPrint(gpa, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
        errdefer gpa.free(arg);
        try result.append(gpa, arg);
    }

    try utils.appendClone(gpa, &result, args.id);

    for (args.command) |e| {
        try utils.appendClone(gpa, &result, e);
    }

    return try result.toOwnedSlice(gpa);
}

pub fn stopContainer(gpa: std.mem.Allocator, id: []const u8) (std.process.Child.RunError || errors.PodmanErrors || std.Io.Writer.Error)!void {
    const argv = [_][]const u8{
        "podman",
        "container",
        "stop",
        "--ignore",
        id,
    };
    const stdout = try call(gpa, &argv);
    defer gpa.free(stdout);
    log.debug("stopContainer received the following from podman: {s}", .{stdout});
}

pub fn startContainer(gpa: std.mem.Allocator, id: []const u8) (std.process.Child.RunError || errors.PodmanErrors || std.Io.Writer.Error)!void {
    const argv = [_][]const u8{
        "podman",
        "container",
        "start",
        id,
    };
    const stdout = try call(gpa, &argv);
    defer gpa.free(stdout);
    log.debug("startContainer received the following from podman: {s}", .{stdout});
}

pub fn deleteContainer(gpa: std.mem.Allocator, id: []const u8, force: bool) (std.process.Child.RunError || errors.PodmanErrors || std.Io.Writer.Error)!void {
    const base_argv = [_][]const u8{
        "podman",
        "container",
        "rm",
        "--ignore",
    };
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    try args.ensureUnusedCapacity(gpa, base_argv.len + 2);
    args.appendSliceAssumeCapacity(&base_argv);
    if (force) {
        args.appendAssumeCapacity("--force");
    }
    args.appendAssumeCapacity(id);
    const stdout = try call(gpa, args.items);
    defer gpa.free(stdout);
    log.debug("deleteContainer received the following from podman: {s}", .{stdout});
}

pub fn deleteImage(gpa: std.mem.Allocator, id: []const u8, force: bool) (std.process.Child.RunError || errors.PodmanErrors || std.Io.Writer.Error)!void {
    const base_argv = [_][]const u8{
        "podman",
        "image",
        "rm",
        "--ignore",
    };
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(gpa);
    try args.ensureUnusedCapacity(gpa, base_argv.len + 2);
    args.appendSliceAssumeCapacity(base_argv);
    if (force) {
        args.appendAssumeCapacity("--force");
    }
    args.appendAssumeCapacity(id);

    const stdout = try call(gpa, args.items);
    defer gpa.free(stdout);
    log.debug("deleteImage received the following from podman: {s}", .{stdout});
}

const create_base = [_][]const u8{
    "podman",
    "create",
    "--cgroupns",
    "host",
    "--dns",
    "none",
    "--ipc",
    "host",
    "--network",
    "host",
    "--no-hosts",
    "--pid",
    "host",
    "--privileged",
    "--security-opt",
    "label=disable",
    "--ulimit",
    "host",
    "--userns",
    "keep-id",
    "--user",
    "root:root",
    "--name",
};

const CreateContainerArguments = struct {
    env: std.process.EnvMap,
    key: []const u8,
    name: []const u8,
    image: Image,
    entrypoint_argv: []const []const u8,
    mounts: []const container.Mount,
};

pub fn createContainer(gpa: std.mem.Allocator, args: CreateContainerArguments) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const tmp_allocator = arena.allocator();

    const argv = try createCreateArgv(tmp_allocator, args);

    const id = try call(gpa, argv);

    return id;
}

fn createCreateArgv(arena: std.mem.Allocator, args: CreateContainerArguments) ![]const []const u8 {
    const labels = try createLabels(arena, args.key);
    const mounts = try createMounts(arena, args.mounts);
    const envs = try createEnvs(arena, args.env);

    const base = create_base ++ [_][]const u8{args.name};

    const argv = try std.mem.concat(arena, []const u8, &[_][]const []const u8{
        &base,
        envs,
        labels,
        mounts,
        &[_][]const u8{args.image.id},
        args.entrypoint_argv,
    });

    return argv;
}

test createCreateArgv {
    var helper_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer helper_arena.deinit();
    const helper_allocator = helper_arena.allocator();
    // setup
    const mounts = [_]container.Mount{
        container.Mount{
            .destination = "/test",
            .source = "/test",
            .kind = .{ .devpts = .{} },
            .options = .{ .rw = true },
            .propagation = .none,
        },
    };

    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    const env_key = "XDG_RUNTIME_DIR";
    const env_val = "/run/hi";
    try env.put(env_key, env_val);

    const img = b: {
        var img: Image = undefined;
        img.id = "hello";
        break :b img;
    };

    const entrypoint_argv = [_][]const u8{
        "test",
        "test",
    };

    const key = "key";

    const name = "name";

    const expected = &create_base ++ &[_][]const u8{
        name,
        "--env",
        env_key ++ "=" ++ env_val,
        "--label",
        label ++ "=" ++ key,
        "--mount=type=devpts,destination=" ++ mounts[0].destination ++ ",ro=false,exec",
        img.id,
    } ++ entrypoint_argv;

    // do
    const args = try createCreateArgv(helper_allocator, .{
        .entrypoint_argv = &entrypoint_argv,
        .env = env,
        .image = img,
        .mounts = &mounts,
        .key = key,
        .name = name,
    });

    // check
    outer: for (expected) |e| {
        for (args) |a| {
            if (std.mem.eql(u8, e, a)) {
                continue :outer;
            }
        } else {
            const stderr = std.debug.lockStderrWriter(&.{});
            defer std.debug.unlockStderrWriter();
            stderr.print("missing value: {s}\nhad: {{", .{e}) catch {};
            if (args.len > 0) {
                stderr.writeAll(args[0]) catch {};
                for (args[1..]) |a| {
                    stderr.print(", {s}", .{a}) catch {};
                }
            }
            stderr.writeAll("}\n") catch {};
            return error.TestValueNotFound;
        }
    }
}

fn createEnvs(gpa: std.mem.Allocator, env: std.process.EnvMap) ![]const []const u8 {
    const minimum_env = [_][]const u8{
        "XDG_RUNTIME_DIR",
    };
    for (minimum_env) |v| {
        if (env.get(v) == null) {
            return error.NeededEnvironmentVariableNotFound;
        }
    }

    var list = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (list.items) |e| {
            gpa.free(e);
        }
        list.deinit(gpa);
    }

    try list.ensureUnusedCapacity(gpa, 2 * env.count());
    var iter = env.iterator();
    while (iter.next()) |entry| {
        list.appendAssumeCapacity(try gpa.dupe(u8, "--env"));
        try utils.appendFormat(gpa, &list, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
    }

    return try list.toOwnedSlice(gpa);
}

test createEnvs {
    var env = std.process.EnvMap.init(std.testing.allocator);
    defer env.deinit();
    const key1 = "abc";
    const value1 = "efg";
    try env.put(key1, value1);
    const shouldErr = createEnvs(std.testing.allocator, env);
    defer {
        if (shouldErr) |list| {
            for (list) |e| {
                std.testing.allocator.free(e);
            }
            std.testing.allocator.free(list);
        } else |_| {}
    }
    try std.testing.expectError(error.NeededEnvironmentVariableNotFound, shouldErr);
    const key2 = "XDG_RUNTIME_DIR";
    const value2 = "abcdef";
    try env.put(key2, value2);
    const cli = try createEnvs(std.testing.allocator, env);
    defer {
        for (cli) |e| {
            std.testing.allocator.free(e);
        }
        std.testing.allocator.free(cli);
    }
    try std.testing.expectEqual(4, cli.len);
    try std.testing.expectEqualStrings("--env", cli[0]);
    try std.testing.expectEqualStrings("--env", cli[2]);
    const pair1 = key1 ++ "=" ++ value1;
    const pair2 = key2 ++ "=" ++ value2;
    if (std.mem.eql(u8, pair1, cli[1])) {
        try std.testing.expectEqualStrings(pair1, cli[1]);
        try std.testing.expectEqualStrings(pair2, cli[3]);
    } else {
        try std.testing.expectEqualStrings(pair2, cli[1]);
        try std.testing.expectEqualStrings(pair1, cli[3]);
    }
}

fn createMounts(gpa: std.mem.Allocator, mounts: []const container.Mount) ![]const []const u8 {
    var list = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (list.items) |e| {
            gpa.free(e);
        }
        list.deinit(gpa);
    }

    for (mounts) |m| {
        var arg = std.ArrayListUnmanaged(u8).empty;
        defer arg.deinit(gpa);
        const writer = arg.writer(gpa);

        try writer.writeAll("--mount=type=");
        switch (m.kind) {
            .bind => |bind_mount| {
                try writer.writeAll("bind,");
                if (!bind_mount.recursive) {
                    try writer.writeAll("bind-nonrecursive,");
                }
                try writer.print("source={s}", .{m.source});
            },
            .volume => |volume_mount| try writer.print("volume,source={s}", .{volume_mount.name}),
            .devpts => try writer.writeAll("devpts"),
        }
        try writer.print(",destination={s},ro={}", .{
            m.destination,
            !m.options.rw,
        });
        if (m.options.dev) {
            try writer.writeAll(",dev");
        }
        if (m.options.exec) {
            try writer.writeAll(",exec");
        }
        if (m.options.suid) {
            try writer.writeAll(",suid");
        }
        if (m.propagation != .none) {
            try writer.writeByte(',');
            try writer.writeAll(@tagName(m.propagation));
        }
        const as_slice = try arg.toOwnedSlice(gpa);
        errdefer gpa.free(as_slice);
        try list.append(gpa, as_slice);
    }

    return list.toOwnedSlice(gpa);
}

test createMounts {
    const vol = container.Mount{
        .source = "/root/.local/share/containers/storage/volumes/dsgdsfgdfsg/_data",
        .destination = "/run/test",
        .options = .{
            .dev = true,
            .exec = false,
            .rw = false,
            .suid = true,
        },
        .propagation = .none,
        .kind = .{ .volume = .{ .name = "vol1" } },
    };
    const vol_expected = "--mount=type=volume,source=vol1,destination=/run/test,ro=true,dev,suid";
    const bind = container.Mount{
        .source = "/root/Documents",
        .destination = "/root/Documents",
        .options = .{
            .dev = false,
            .exec = true,
            .rw = true,
            .suid = false,
        },
        .propagation = .rprivate,
        .kind = .{ .bind = .{ .recursive = true } },
    };
    const bind_expected = "--mount=type=bind,source=/root/Documents,destination=/root/Documents,ro=false,exec,rprivate";
    const devpts = container.Mount{
        .source = "something",
        .destination = "/dev/pts",
        .options = .{
            .rw = false,
        },
        .propagation = .runbindable,
        .kind = .{ .devpts = .{} },
    };
    const devpts_expected = "--mount=type=devpts,destination=/dev/pts,ro=true,exec,runbindable";
    const actual = try createMounts(std.testing.allocator, &[_]container.Mount{ vol, bind, devpts });
    defer {
        for (actual) |e| {
            std.testing.allocator.free(e);
        }
        std.testing.allocator.free(actual);
    }
    try std.testing.expectEqual(3, actual.len);
    try std.testing.expectEqualStrings(vol_expected, actual[0]);
    try std.testing.expectEqualStrings(bind_expected, actual[1]);
    try std.testing.expectEqualStrings(devpts_expected, actual[2]);
}

fn createLabels(gpa: std.mem.Allocator, key: []const u8) ![]const []const u8 {
    var list = std.ArrayListUnmanaged([]const u8).empty;
    defer {
        for (list.items) |e| {
            gpa.free(e);
        }
        list.deinit(gpa);
    }

    const marker = "--label";

    {
        const marker_copy = try gpa.dupe(u8, marker);
        list.append(gpa, marker_copy) catch |err| {
            gpa.free(marker_copy);
            return err;
        };

        const arg = try std.mem.concat(gpa, u8, &[_][]const u8{ label ++ "=", key });
        list.append(gpa, arg) catch |err| {
            gpa.free(arg);
            return err;
        };
    }

    return try list.toOwnedSlice(gpa);
}

test createLabels {
    const key = "hello";
    const labels = try createLabels(std.testing.allocator, key);
    defer {
        for (labels) |e| {
            std.testing.allocator.free(e);
        }
        std.testing.allocator.free(labels);
    }

    try std.testing.expectEqual(2, labels.len);
    try std.testing.expectEqualStrings("--label", labels[0]);
    try std.testing.expectEqualStrings(label ++ "=" ++ key, labels[1]);
}

pub fn listContainers(gpa: std.mem.Allocator, key: []const u8) ![]Container {
    if (utils.isInsideContainer() and !utils.isInsideLibnexpodContainer()) {
        return errors.LibnexpodErrors.InsideNonLibnexpodContainer;
    }

    var tmp_arena = std.heap.ArenaAllocator.init(gpa);
    defer tmp_arena.deinit();
    const tmp_allocator = tmp_arena.allocator();

    const ids = try call(tmp_allocator, &.{
        "podman",
        "container",
        "list",
        "--all",
        "--format",
        "{{ .ID }}",
        "--filter",
        try std.mem.concat(tmp_allocator, u8, &.{ "label=" ++ label ++ "=", key }),
    });
    log.debug("podman.listContainers received the following IDs from podman: {s}", .{b: {
        if (log.enabled(.debug)) {
            const dupe = try tmp_allocator.dupe(u8, ids);

            std.mem.replaceScalar(u8, dupe, '\n', ',');
            break :b dupe;
        } else {
            break :b "<placeholder>";
        }
    }});

    const amount = std.mem.count(u8, ids, "\n");
    var result = try std.ArrayListUnmanaged(Container).initCapacity(gpa, amount);
    errdefer {
        for (result.items) |e| {
            e.deinit();
        }
        result.deinit(gpa);
    }

    var iter = std.mem.tokenizeScalar(u8, ids, '\n');
    while (iter.next()) |next| {
        result.appendAssumeCapacity(try getContainer(gpa, key, next));
    }

    return try result.toOwnedSlice(gpa);
}

pub fn getContainer(gpa: std.mem.Allocator, key: []const u8, id: []const u8) !Container {
    if (utils.isInsideContainer() and !utils.isInsideLibnexpodContainer()) {
        return errors.LibnexpodErrors.InsideNonLibnexpodContainer;
    }

    var tmp_arena = std.heap.ArenaAllocator.init(gpa);
    defer tmp_arena.deinit();
    const tmp_allocator = tmp_arena.allocator();

    const json = try call(tmp_allocator, &.{
        "podman",
        "container",
        "inspect",
        "--format",
        "{{ json . }}",
        id,
    });
    log.debug("podman.getContainer received the following JSON for the container with the ID {s}: {s}", .{ id, json });

    const con = try parseContainer(gpa, json);
    errdefer con.deinit();

    const con_key = con.config.labels.get(label) orelse return errors.LibnexpodErrors.NoLibnexpodContainer;
    if (std.mem.eql(u8, key, con_key)) {
        return con;
    } else {
        return errors.LibnexpodErrors.NoLibnexpodContainer;
    }
}

fn parseContainer(gpa: std.mem.Allocator, json: []const u8) !Container {
    var tmp_arena = std.heap.ArenaAllocator.init(gpa);
    defer tmp_arena.deinit();
    const tmp_allocator = tmp_arena.allocator();

    const parsed = try std.json.parseFromSliceLeaky(ContainerMarshall, tmp_allocator, json, .{ .ignore_unknown_fields = true });

    if (parsed.Config.Labels != .object) return std.json.ParseFromValueError.UnexpectedToken;
    if (parsed.Config.Annotations != .object) return std.json.ParseFromValueError.UnexpectedToken;
    if (!(parsed.Config.StopSignal == .string or parsed.Config.StopSignal == .integer)) return std.json.ParseFromValueError.UnexpectedToken;

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const local_allocator = arena.allocator();
    return .{
        .id = try local_allocator.dupe(u8, parsed.Id),
        .name = try local_allocator.dupe(u8, parsed.Name),
        .image_id = try local_allocator.dupe(u8, parsed.Image),
        .created = zeit.instant(.{
            .source = .{
                .rfc3339 = parsed.Created,
            },
        }) catch |err| switch (err) {
            error.InvalidFormat, error.UnhandledFormat, error.InvalidISO8601 => return std.json.ParseFromValueError.InvalidCharacter,
            else => |rest| return rest,
        },
        .mounts = b: {
            var mounts = try local_allocator.alloc(container.Mount, parsed.Mounts.len);
            for (parsed.Mounts, 0..) |e, i| {
                const propagation = val: {
                    if (std.mem.eql(u8, "shared", e.Propagation)) {
                        break :val container.PropagationOptions.shared;
                    } else if (std.mem.eql(u8, "rshared", e.Propagation)) {
                        break :val container.PropagationOptions.rshared;
                    } else if (std.mem.eql(u8, "slave", e.Propagation)) {
                        break :val container.PropagationOptions.slave;
                    } else if (std.mem.eql(u8, "rslave", e.Propagation)) {
                        break :val container.PropagationOptions.rslave;
                    } else if (std.mem.eql(u8, "private", e.Propagation)) {
                        break :val container.PropagationOptions.private;
                    } else if (std.mem.eql(u8, "rprivate", e.Propagation)) {
                        break :val container.PropagationOptions.rprivate;
                    } else if (std.mem.eql(u8, "unbindable", e.Propagation)) {
                        break :val container.PropagationOptions.unbindable;
                    } else if (std.mem.eql(u8, "runbindable", e.Propagation)) {
                        break :val container.PropagationOptions.runbindable;
                    } else if (std.mem.eql(u8, "", e.Propagation)) {
                        break :val container.PropagationOptions.none;
                    } else {
                        log.err("found unknown mount propagation: {s}", .{e.Propagation});
                        return std.json.ParseFromValueError.UnexpectedToken;
                    }
                };
                var mount = val: {
                    if (std.mem.eql(u8, "devpts", e.Source)) {
                        break :val container.Mount{
                            .source = e.Source,
                            .destination = e.Destination,
                            .propagation = propagation,
                            .kind = .{ .devpts = .{} },
                            .options = .{ .rw = e.RW },
                        };
                    } else if (std.mem.eql(u8, "bind", e.Type)) {
                        break :val container.Mount{
                            .source = e.Source,
                            .destination = e.Destination,
                            .propagation = propagation,
                            .kind = .{ .bind = .{} },
                            .options = .{ .rw = e.RW },
                        };
                    } else if (std.mem.eql(u8, "volume", e.Type)) {
                        if (e.Name == null) {
                            return std.json.ParseFromValueError.MissingField;
                        }
                        const name = e.Name.?;
                        break :val container.Mount{
                            .source = e.Source,
                            .destination = e.Destination,
                            .propagation = propagation,
                            .kind = .{ .volume = .{ .name = name } },
                            .options = .{ .rw = e.RW },
                        };
                    } else {
                        return std.json.ParseFromValueError.UnknownField;
                    }
                };
                for (e.Options) |op| {
                    if (std.mem.eql(u8, "suid", op)) {
                        mount.options.suid = true;
                    } else if (std.mem.eql(u8, "exec", op)) {
                        mount.options.exec = true;
                    } else if (std.mem.eql(u8, "dev", op)) {
                        mount.options.dev = true;
                    } else if (std.mem.eql(u8, "rbind", op)) {
                        mount.kind.bind.recursive = true;
                    } else if (std.mem.eql(u8, "nosuid", op) or std.mem.eql(u8, "noexec", op) or std.mem.eql(u8, "nodev", op) or std.mem.eql(u8, "bind", op)) {
                        continue;
                    } else {
                        log.info("encountered unknown mount option, please report upstream if you think it should be added: {s}", .{op});
                    }
                }
                mounts[i] = mount;
            }
            break :b mounts;
        },
        .state = b: {
            if (std.mem.eql(u8, "created", parsed.State.Status)) {
                break :b container.State.Created;
            } else if (std.mem.eql(u8, "running", parsed.State.Status)) {
                break :b container.State.Running;
            } else if (std.mem.eql(u8, "exited", parsed.State.Status)) {
                break :b container.State.Exited;
            } else {
                break :b container.State.Unknown;
            }
        },
        .idmappings = .{
            .uids = b: {
                var uids = try local_allocator.alloc(container.IdMapping(std.posix.uid_t), parsed.HostConfig.IDMappings.UidMap.len);
                for (parsed.HostConfig.IDMappings.UidMap, 0..) |e, i| {
                    const sep1 = std.mem.indexOf(u8, e, ":") orelse return std.json.ParseFromValueError.InvalidCharacter;
                    const sep2 = std.mem.lastIndexOf(u8, e, ":") orelse return std.json.ParseFromValueError.InvalidCharacter;
                    const container_uid = try std.fmt.parseInt(std.posix.uid_t, e[0..sep1], 10);
                    const host_uid = try std.fmt.parseInt(std.posix.uid_t, e[sep1 + 1 .. sep2], 10);
                    const amount = try std.fmt.parseInt(usize, e[sep2 + 1 .. e.len], 10);
                    uids[i] = .{
                        .start_container = container_uid,
                        .start_host = host_uid,
                        .amount = amount,
                    };
                }
                break :b uids;
            },
            .gids = b: {
                var gids = try local_allocator.alloc(container.IdMapping(std.posix.gid_t), parsed.HostConfig.IDMappings.GidMap.len);
                for (parsed.HostConfig.IDMappings.GidMap, 0..) |e, i| {
                    const sep1 = std.mem.indexOf(u8, e, ":") orelse return std.json.ParseFromValueError.InvalidCharacter;
                    const sep2 = std.mem.lastIndexOf(u8, e, ":") orelse return std.json.ParseFromValueError.InvalidCharacter;
                    const container_gid = try std.fmt.parseInt(std.posix.uid_t, e[0..sep1], 10);
                    const host_gid = try std.fmt.parseInt(std.posix.uid_t, e[sep1 + 1 .. sep2], 10);
                    const amount = try std.fmt.parseInt(usize, e[sep2 + 1 .. e.len], 10);
                    gids[i] = .{
                        .start_container = container_gid,
                        .start_host = host_gid,
                        .amount = amount,
                    };
                }
                break :b gids;
            },
        },
        .config = .{
            .hostname = try local_allocator.dupe(u8, parsed.Config.Hostname),
            .working_dir = try local_allocator.dupe(u8, parsed.Config.WorkingDir),
            .umask = try std.fmt.parseInt(std.posix.mode_t, parsed.Config.Umask, 8),
            .stop_signal = b: {
                if (parsed.Config.StopSignal == .string) {
                    inline for (comptime std.meta.declarations(std.posix.SIG)) |field| {
                        const value = @field(std.posix.SIG, field.name);
                        const type_info = @typeInfo(@TypeOf(value));
                        if (type_info == .int or type_info == .comptime_int) {
                            if (std.mem.eql(u8, "SIG" ++ field.name, parsed.Config.StopSignal.string)) {
                                break :b value;
                            }
                        }
                    } else {
                        return std.json.ParseFromValueError.UnexpectedToken;
                    }
                } else {
                    break :b @intCast(parsed.Config.StopSignal.integer);
                }
            },
            .cmd = b: {
                var cmd = try local_allocator.alloc([]const u8, parsed.Config.Cmd.len);
                for (parsed.Config.Cmd, 0..) |e, i| {
                    cmd[i] = try local_allocator.dupe(u8, e);
                }
                break :b cmd;
            },
            .create_command = b: {
                var create_command = try local_allocator.alloc([]const u8, parsed.Config.CreateCommand.len);
                for (parsed.Config.CreateCommand, 0..) |e, i| {
                    create_command[i] = try local_allocator.dupe(u8, e);
                }
                break :b create_command;
            },
            .env = b: {
                var env = std.process.EnvMap.init(local_allocator);
                for (parsed.Config.Env) |variable| {
                    const separator = val: {
                        if (std.mem.indexOf(u8, variable, "=")) |sep| {
                            break :val sep;
                        } else {
                            return std.json.ParseFromValueError.UnexpectedToken;
                        }
                    };
                    const key = variable[0..separator];
                    const value = variable[separator + 1 .. variable.len];
                    if (env.hash_map.contains(key)) {
                        return std.json.ParseFromValueError.DuplicateField;
                    } else {
                        try env.put(key, value);
                    }
                }
                break :b env;
            },
            .labels = b: {
                var labels = std.StringHashMapUnmanaged([]const u8).empty;
                var iter = parsed.Config.Labels.object.iterator();
                while (iter.next()) |entry| {
                    if (entry.value_ptr.* != .string) {
                        return std.json.ParseFromValueError.UnexpectedToken;
                    }
                    const key = try local_allocator.dupe(u8, entry.key_ptr.*);
                    const value = try local_allocator.dupe(u8, entry.value_ptr.*.string);
                    try labels.put(local_allocator, key, value);
                }
                break :b labels;
            },
            .annotations = b: {
                var annotations = std.StringHashMapUnmanaged([]const u8).empty;
                var iter = parsed.Config.Annotations.object.iterator();
                while (iter.next()) |entry| {
                    if (entry.value_ptr.* != .string) {
                        return std.json.ParseFromValueError.UnexpectedToken;
                    }
                    const key = try local_allocator.dupe(u8, entry.key_ptr.*);
                    const value = try local_allocator.dupe(u8, entry.value_ptr.*.string);
                    try annotations.put(local_allocator, key, value);
                }
                break :b annotations;
            },
        },
        .arena = arena,
    };
}

const ContainerMarshall = struct {
    Id: []const u8,
    Name: []const u8,
    Image: []const u8,
    Mounts: []const MountMarshall,
    Created: []const u8,
    Config: struct {
        Hostname: []const u8,
        Env: []const []const u8,
        Cmd: []const []const u8,
        WorkingDir: []const u8,
        Labels: std.json.Value,
        Annotations: std.json.Value,
        StopSignal: std.json.Value,
        CreateCommand: []const []const u8,
        Umask: []const u8,
    },
    HostConfig: struct {
        IDMappings: struct {
            UidMap: []const []const u8,
            GidMap: []const []const u8,
        },
    },
    State: struct {
        Status: []const u8,
    },
};

const MountMarshall = struct {
    Type: []const u8,
    Source: []const u8,
    Destination: []const u8,
    Options: []const []const u8,
    RW: bool,
    Propagation: []const u8,
    Name: ?[]const u8 = null,
};

pub fn listImages(gpa: std.mem.Allocator) ![]Image {
    if (utils.isInsideContainer() and !utils.isInsideLibnexpodContainer()) {
        return errors.LibnexpodErrors.InsideNonLibnexpodContainer;
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const tmp_allocator = arena.allocator();

    const ids = try call(tmp_allocator, &.{
        "podman",
        "images",
        "--format",
        "{{ .Id }}",
        "--filter",
        "label=" ++ label,
    });
    log.debug("podman.listImages received the following IDs from podman: {s}", .{b: {
        if (log.enabled(.debug)) {
            const dupe = try tmp_allocator.dupe(u8, ids);

            std.mem.replaceScalar(u8, dupe, '\n', ',');
            break :b dupe;
        } else {
            break :b "<placeholder>";
        }
    }});

    const amount = std.mem.count(u8, ids, "\n");
    var result = try std.ArrayListUnmanaged(Image).initCapacity(gpa, amount);
    errdefer {
        for (result.items) |e| {
            e.deinit();
        }
        result.deinit(gpa);
    }

    var iter = std.mem.tokenizeScalar(u8, ids, '\n');
    while (iter.next()) |next| {
        result.appendAssumeCapacity(try getImage(gpa, next));
    }

    return try result.toOwnedSlice(gpa);
}

pub fn getImage(gpa: std.mem.Allocator, id: []const u8) !Image {
    var tmp_arena = std.heap.ArenaAllocator.init(gpa);
    defer tmp_arena.deinit();
    const tmp_allocator = tmp_arena.allocator();

    var json = try call(tmp_allocator, &.{
        "podman",
        "image",
        "inspect",
        "--format",
        "{{ json . }}",
        id,
    });
    if (json[json.len - 1] == '\n') json.len -= 1;
    log.debug("podman.getImage received the following JSON for the image with the ID {s}: {s}", .{ id, json });

    return try parseImage(gpa, json);
}

fn parseImage(gpa: std.mem.Allocator, json: []const u8) !Image {
    var tmp_arena = std.heap.ArenaAllocator.init(gpa);
    defer tmp_arena.deinit();
    const tmp_allocator = tmp_arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(ImageMarshal, tmp_allocator, json, .{ .ignore_unknown_fields = true });

    if (parsed.Config.Labels != .object) return std.json.ParseFromValueError.UnexpectedToken;

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const local_allocator = arena.allocator();
    return .{
        .id = try local_allocator.dupe(u8, parsed.Id),
        .created = zeit.instant(.{
            .source = .{
                .rfc3339 = parsed.Created,
            },
        }) catch |err| switch (err) {
            error.InvalidFormat, error.UnhandledFormat, error.InvalidISO8601 => return std.json.ParseFromValueError.InvalidCharacter,
            else => |rest| return rest,
        },
        .names = b: {
            var names = try local_allocator.alloc(image.Name, parsed.RepoTags.len);
            for (parsed.RepoTags, 0..) |e, i| {
                const repo_name_sep = val: {
                    if (std.mem.lastIndexOf(u8, e, "/")) |sep| {
                        break :val sep;
                    } else {
                        return std.json.ParseFromValueError.UnexpectedToken;
                    }
                };
                const name_tag_sep = val: {
                    if (std.mem.lastIndexOf(u8, e, ":")) |sep| {
                        break :val sep;
                    } else {
                        return std.json.ParseFromValueError.UnexpectedToken;
                    }
                };
                const repo = e[0..repo_name_sep];
                const name = e[repo_name_sep + 1 .. name_tag_sep];
                const tag = e[name_tag_sep + 1 .. e.len];
                names[i] = .{
                    .repo = try local_allocator.dupe(u8, repo),
                    .name = try local_allocator.dupe(u8, name),
                    .tag = try local_allocator.dupe(u8, tag),
                };
            }
            break :b names;
        },
        .version = if (parsed.Version) |v|
            try local_allocator.dupe(u8, v)
        else if (parsed.Config.Labels.object.get("version")) |v|
            try local_allocator.dupe(u8, if (v == .string) v.string else return std.json.ParseFromValueError.UnexpectedToken)
        else
            null,
        .author = if (parsed.Author) |a|
            try local_allocator.dupe(u8, a)
        else if (parsed.Config.Labels.object.get("maintainer")) |a|
            try local_allocator.dupe(u8, if (a == .string) a.string else return std.json.ParseFromValueError.UnexpectedToken)
        else
            null,
        .config = .{
            .working_dir = if (parsed.Config.WorkingDir) |wd|
                try local_allocator.dupe(u8, wd)
            else
                null,
            .cmd = b: {
                var cmd = try local_allocator.alloc([]const u8, parsed.Config.Cmd.len);
                for (parsed.Config.Cmd, 0..) |c, i| {
                    cmd[i] = try local_allocator.dupe(u8, c);
                }
                break :b cmd;
            },
            .env = b: {
                var env = std.process.EnvMap.init(local_allocator);
                for (parsed.Config.Env) |variable| {
                    const sep = std.mem.indexOfScalar(u8, variable, '=') orelse return std.json.ParseFromValueError.UnexpectedToken;
                    const key = variable[0..sep];
                    const value = variable[sep + 1 ..];
                    if (env.hash_map.contains("key")) {
                        return std.json.ParseFromValueError.DuplicateField;
                    } else {
                        try env.put(key, value);
                    }
                }
                break :b env;
            },
            .labels = b: {
                var labels = std.StringHashMapUnmanaged([]const u8).empty;
                var iter = parsed.Config.Labels.object.iterator();
                while (iter.next()) |entry| {
                    if (entry.value_ptr.* != .string) {
                        return std.json.ParseFromValueError.UnexpectedToken;
                    }
                    const key = try local_allocator.dupe(u8, entry.key_ptr.*);
                    const value = try local_allocator.dupe(u8, entry.value_ptr.*.string);
                    try labels.put(local_allocator, key, value);
                }
                break :b labels;
            },
        },
        .arena = arena,
    };
}

const ImageMarshal = struct {
    Id: []const u8,
    RepoTags: []const []const u8,
    Created: []const u8,
    Version: ?[]const u8 = null,
    Author: ?[]const u8 = null,
    Config: struct {
        Env: []const []const u8,
        Cmd: []const []const u8,
        Labels: std.json.Value,
        WorkingDir: ?[]const u8 = null,
    },
};

fn call(gpa: std.mem.Allocator, argv: []const []const u8) (std.process.Child.RunError || errors.PodmanErrors || std.Io.Writer.Error)![]const u8 {
    const result = std.process.Child.run(.{
        .allocator = gpa,
        .argv = argv,
        .max_output_bytes = comptime std.math.maxInt(usize),
    }) catch |err| switch (err) {
        error.FileNotFound => {
            log.err("podman not found", .{});
            return errors.PodmanErrors.PodmanNotFound;
        },
        else => |rest| return rest,
    };
    errdefer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .Exited => |code| {
            if (code == 0) {
                return result.stdout;
            } else {
                var argv_str: std.Io.Writer.Allocating = .init(gpa);
                defer argv_str.deinit();
                try argv_str.writer.writeByte('[');
                if (argv.len > 0) {
                    for (argv[0 .. argv.len - 1]) |e| {
                        try argv_str.writer.print("{s}, ", .{e});
                    }
                    try argv_str.writer.print("{s}", .{argv[argv.len - 1]});
                }
                try argv_str.writer.writeByte(']');
                const stderr = if (result.stderr.len > 0 and result.stderr[result.stderr.len - 1] == '\n')
                    result.stderr[0 .. result.stderr.len - 1]
                else
                    result.stderr;
                log.err("Call to podman exited with: {}", .{code});
                log.err("stderr output: {s}", .{stderr});
                log.err("argv was: {s}", .{argv_str.writer.buffer});
                return errors.PodmanErrors.PodmanFailed;
            }
        },
        else => |code| {
            log.err("Podman exited unexpectedly with {any}\n{s}\n{s}", .{ code, result.stdout, result.stderr });
            return errors.PodmanErrors.PodmanUnexpectedExit;
        },
    }
}
test call {
    const msg = "Hello";
    const example = [_][]const u8{
        "echo",
        msg,
    };
    const result = try call(std.testing.allocator, &example);
    defer std.testing.allocator.free(result);
    std.testing.expect(std.mem.eql(u8, msg ++ "\n", result)) catch |err| {
        std.debug.print("{s}", .{result});
        return err;
    };
}

test "makeFromJson Image" {
    const id = "a68bd4c6bc4d33757916b2090886d35992933f0fd53590d3c89340446c0dfb16";
    const created_string = "2024-05-23T05:48:16.902538868Z";
    const created = try zeit.instant(.{
        .source = .{
            .rfc3339 = created_string,
        },
    });
    const author = "Fedora Project Contributors <devel@lists.fedoraproject.org>";
    const version = "";
    const names = [_]image.Name{
        .{
            .repo = "registry.fedoraproject.org",
            .name = "fedora-toolbox",
            .tag = "40",
        },
        .{
            .repo = "localhost",
            .name = "test",
            .tag = "latest",
        },
    };
    const label_keys = [_][]const u8{
        "com.github.containers.toolbox",
        "io.buildah.version",
        "license",
        "name",
        "org.opencontainers.image.license",
        "org.opencontainers.image.name",
        "org.opencontainers.image.url",
        "org.opencontainers.image.vendor",
        "org.opencontainers.image.version",
        "vendor",
        "version",
    };
    const label_values = [_][]const u8{
        "true",
        "1.35.3",
        "MIT",
        "fedora-toolbox",
        "MIT",
        "fedora-toolbox",
        "https://fedoraproject.org/",
        "Fedora Project",
        "40",
        "Fedora Project",
        "40",
    };
    // this key was not the original image, but I added it for testing
    const working_dir = "/";
    const cmd = [_][]const u8{
        "/bin/bash",
    };
    const env_keys = [_][]const u8{
        "container",
    };
    const env_values = [_][]const u8{
        "oci",
    };
    const json =
        \\{
        \\"Id": "a68bd4c6bc4d33757916b2090886d35992933f0fd53590d3c89340446c0dfb16",
        \\"Digest": "sha256:489af52398c4f3ed338b581f62d3b960149f16f64c68da2320e924f77477742f",
        \\"RepoTags": [
        \\"registry.fedoraproject.org/fedora-toolbox:40",
        \\"localhost/test:latest"
        \\],
        \\"RepoDigests": [
        \\"registry.fedoraproject.org/fedora-toolbox@sha256:0895aa9c53ec01ca630541d060c1dd9e43a03f4eece4b491778ff920604f6ed7",
        \\"registry.fedoraproject.org/fedora-toolbox@sha256:489af52398c4f3ed338b581f62d3b960149f16f64c68da2320e924f77477742f"
        \\],
        \\"Parent": "",
        \\"Comment": "",
        \\"Created": "2024-05-23T05:48:16.902538868Z",
        \\"Config": {
        \\"Env": [
        \\"container=oci"
        \\],
        \\"Cmd": [
        \\"/bin/bash"
        \\],
        \\"WorkingDir": "/",
        \\"Labels": {
        \\"com.github.containers.toolbox": "true",
        \\"io.buildah.version": "1.35.3",
        \\"license": "MIT",
        \\"name": "fedora-toolbox",
        \\"org.opencontainers.image.license": "MIT",
        \\"org.opencontainers.image.name": "fedora-toolbox",
        \\"org.opencontainers.image.url": "https://fedoraproject.org/",
        \\"org.opencontainers.image.vendor": "Fedora Project",
        \\"org.opencontainers.image.version": "40",
        \\"vendor": "Fedora Project",
        \\"version": "40"
        \\}
        \\},
        \\"Version": "",
        \\"Author": "Fedora Project Contributors <devel@lists.fedoraproject.org>",
        \\"Architecture": "amd64",
        \\"Os": "linux",
        \\"Size": 2145220341,
        \\"VirtualSize": 2145220341,
        \\"GraphDriver": {
        \\"Name": "overlay",
        \\"Data": {
        \\"UpperDir": "/var/home/kilian/.local/share/containers/storage/overlay/bbfb37c5b121e26d59f53fe96681293fdc361658b8988edfeeca127d4d33f6ac/diff",
        \\"WorkDir": "/var/home/kilian/.local/share/containers/storage/overlay/bbfb37c5b121e26d59f53fe96681293fdc361658b8988edfeeca127d4d33f6ac/work"
        \\}
        \\},
        \\"RootFS": {
        \\"Type": "layers",
        \\"Layers": [
        \\"sha256:bbfb37c5b121e26d59f53fe96681293fdc361658b8988edfeeca127d4d33f6ac"
        \\]
        \\},
        \\"Labels": {
        \\"com.github.containers.toolbox": "true",
        \\"io.buildah.version": "1.35.3",
        \\"license": "MIT",
        \\"name": "fedora-toolbox",
        \\"org.opencontainers.image.license": "MIT",
        \\"org.opencontainers.image.name": "fedora-toolbox",
        \\"org.opencontainers.image.url": "https://fedoraproject.org/",
        \\"org.opencontainers.image.vendor": "Fedora Project",
        \\"org.opencontainers.image.version": "40",
        \\"vendor": "Fedora Project",
        \\"version": "40"
        \\},
        \\"Annotations": {
        \\"org.opencontainers.image.base.digest": "",
        \\"org.opencontainers.image.base.name": ""
        \\},
        \\"ManifestType": "application/vnd.oci.image.manifest.v1+json",
        \\"User": "",
        \\"History": [
        \\{
        \\"created": "2024-05-23T05:48:29.718235695Z",
        \\"created_by": "KIWI 10.0.11",
        \\"author": "Fedora Project Contributors <devel@lists.fedoraproject.org>"
        \\}
        \\],
        \\"NamesHistory": [
        \\"registry.fedoraproject.org/fedora-toolbox:40"
        \\]
        \\}
    ;
    const parsed = try parseImage(std.testing.allocator, json);
    defer parsed.deinit();
    const img = parsed;
    const expect = std.testing.expect;
    const expectEqualStrings = std.testing.expectEqualStrings;
    try expectEqualStrings(id, img.id);
    try std.testing.expectEqual(created, img.created);
    for (names, img.names) |expected, actual| {
        try expectEqualStrings(expected.repo, actual.repo);
        try expectEqualStrings(expected.name, actual.name);
        try expectEqualStrings(expected.tag, actual.tag);
    }
    try expect(img.author != null);
    try expectEqualStrings(author, img.author.?);
    try expect(img.version != null);
    try expectEqualStrings(version, img.version.?);
    for (label_keys, label_values) |key, value| {
        try expect(img.config.labels.contains(key));
        try expectEqualStrings(value, img.config.labels.get(key).?);
    }
    for (env_keys, env_values) |key, value| {
        expect(img.config.env.hash_map.contains(key)) catch |err| {
            std.debug.print("missing key: {s}\n", .{key});
            return err;
        };
        try expectEqualStrings(value, img.config.env.get(key).?);
    }
    for (cmd, img.config.cmd) |expected, actual| {
        try expectEqualStrings(expected, actual);
    }
    try expect(img.config.working_dir != null);
    try expectEqualStrings(working_dir, img.config.working_dir.?);
}

test "makeFromJson wrong input" {
    try std.testing.expectError(error.UnexpectedEndOfInput, parseImage(std.testing.allocator, "{"));
}

test "makeFromJson missing" {
    const id = "\"Id\": \"9292\"";
    const created = "\"Created\": \"2024-08-04T00:07:42Z\"";
    const repo_tags = "\"RepoTags\": [\"localhost/image:latest\"]";
    const env = "\"Env\": [\"PATH=/usr/bin:/usr/sbin:/bin:/sbin\"]";
    const cmd = "\"Cmd\": [\"/bin/bash\"]";
    const labels = "\"Labels\": {\"com.github.libnexpod\":\"true\"}";
    {
        const json =
            \\{
        ++ id ++ "," ++ created ++ "," ++ repo_tags ++
            \\}
        ;
        try std.testing.expectError(error.MissingField, parseImage(std.testing.allocator, json));
    }
    {
        const json =
            \\{
        ++ id ++ "," ++ created ++ "," ++ repo_tags ++ "," ++ "\"config\": {" ++ env ++ "," ++ labels ++
            \\}}
        ;
        try std.testing.expectError(error.MissingField, parseImage(std.testing.allocator, json));
    }
    {
        const json =
            \\{
        ++ id ++ "," ++ created ++ "," ++ repo_tags ++ "," ++ "\"config\": {" ++ env ++ "," ++ cmd ++
            \\}}
        ;
        try std.testing.expectError(error.MissingField, parseImage(std.testing.allocator, json));
    }
    {
        const json =
            \\{
        ++ id ++ "," ++ created ++ "," ++ repo_tags ++ "," ++ "\"config\": {" ++ labels ++ "," ++ cmd ++
            \\}}
        ;
        try std.testing.expectError(error.MissingField, parseImage(std.testing.allocator, json));
    }
    {
        const json =
            \\{
        ++ id ++ "," ++ repo_tags ++ "," ++ "\"config\": {" ++ env ++ "," ++ labels ++ "," ++ cmd ++
            \\}}
        ;
        try std.testing.expectError(error.MissingField, parseImage(std.testing.allocator, json));
    }
    {
        const json =
            \\{
        ++ created ++ "," ++ repo_tags ++ "," ++ "\"config\": {" ++ env ++ "," ++ labels ++ "," ++ cmd ++
            \\}}
        ;
        try std.testing.expectError(error.MissingField, parseImage(std.testing.allocator, json));
    }
    {
        const json =
            \\{
        ++ created ++ "," ++ id ++ "," ++ "\"config\": {" ++ env ++ "," ++ labels ++ "," ++ cmd ++
            \\}}
        ;
        try std.testing.expectError(error.MissingField, parseImage(std.testing.allocator, json));
    }
}
test "makeFromJson Container" {
    // this is so far from a toolbx container but with stuff removed because of privacy and size reasons
    // TODO: swap with a libnexpod container
    const id = "1b2001551d16322e8d6b6833548a41dde83b488557deeca44a821ba78fe01656";
    const created = try zeit.instant(.{
        .source = .{
            .rfc3339 = "2024-05-23T21:36:42.621389895+02:00",
        },
    });
    const name = "systemprogrammierung";
    const state = container.State.Exited;
    const image_id = "a68bd4c6bc4d33757916b2090886d35992933f0fd53590d3c89340446c0dfb16";
    const mount0 = container.Mount{
        .source = "/run/user/1000",
        .destination = "/run/user/1000",
        .propagation = .rprivate,
        .options = .{
            .dev = false,
            .suid = false,
            .rw = true,
            .exec = true,
        },
        .kind = .{
            .bind = .{
                .recursive = true,
            },
        },
    };
    const uid0 = container.IdMapping(std.posix.uid_t){
        .start_container = 0,
        .start_host = 1,
        .amount = 1000,
    };
    const gid0 = container.IdMapping(std.posix.gid_t){
        .start_container = 0,
        .start_host = 1,
        .amount = 1000,
    };
    const hostname = "toolbox";
    const cmd = [_][]const u8{
        "toolbox",
        "--log-level",
        "debug",
        "init-container",
        "--gid",
        "1000",
        "--home",
        "/home/kilian",
        "--shell",
        "/bin/bash",
        "--uid",
        "1000",
        "--user",
        "kilian",
        "--home-link",
        "--media-link",
        "--mnt-link",
    };
    const env0_key = "HOME";
    const env0_value = "/root";
    const working_dir = "/";
    const label_key = "com.github.containers.toolbox";
    const label_value = "true";
    const annotation_key = "io.container.manager";
    const annotation_value = "libpod";
    const stop_signal = std.posix.SIG.TERM;
    const create_command = [_][]const u8{
        "podman",
        "--log-level",
        "error",
        "create",
        "--cgroupns",
        "host",
        "--dns",
        "none",
        "--env",
        "TOOLBOX_PATH=/usr/bin/toolbox",
        "--env",
        "XDG_RUNTIME_DIR=/run/user/1000",
        "--hostname",
        "toolbox",
        "--ipc",
        "host",
        "--label",
        "com.github.containers.toolbox=true",
        "--mount",
        "type=devpts,destination=/dev/pts",
        "--name",
        "systemprogrammierung",
        "--network",
        "host",
        "--no-hosts",
        "--pid",
        "host",
        "--privileged",
        "--security-opt",
        "label=disable",
        "--ulimit",
        "host",
        "--userns",
        "keep-id",
        "--user",
        "root:root",
        "--volume",
        "/:/run/host:rslave",
        "--volume",
        "/dev:/dev:rslave",
        "--volume",
        "/run/dbus/system_bus_socket:/run/dbus/system_bus_socket",
        "--volume",
        "/var/home/kilian:/var/home/kilian:rslave",
        "--volume",
        "/usr/bin/toolbox:/usr/bin/toolbox:ro",
        "--volume",
        "/run/user/1000:/run/user/1000",
        "--volume",
        "/run/avahi-daemon/socket:/run/avahi-daemon/socket",
        "--volume",
        "/run/.heim_org.h5l.kcm-socket:/run/.heim_org.h5l.kcm-socket",
        "--volume",
        "/run/pcscd/pcscd.comm:/run/pcscd/pcscd.comm",
        "--volume",
        "/run/media:/run/media:rslave",
        "--volume",
        "/etc/profile.d/toolbox.sh:/etc/profile.d/toolbox.sh:ro",
        "registry.fedoraproject.org/fedora-toolbox:40",
        "toolbox",
        "--log-level",
        "debug",
        "init-container",
        "--gid",
        "1000",
        "--home",
        "/home/kilian",
        "--shell",
        "/bin/bash",
        "--uid",
        "1000",
        "--user",
        "kilian",
        "--home-link",
        "--media-link",
        "--mnt-link",
    };
    const umask: std.posix.mode_t = 0o0022;
    const json =
        \\{
        \\  "Id": "1b2001551d16322e8d6b6833548a41dde83b488557deeca44a821ba78fe01656",
        \\  "Created": "2024-05-23T21:36:42.621389895+02:00",
        // the container name from a container for a university lecture of mine
        \\  "Name": "systemprogrammierung",
        \\  "State": {
        \\    "OciVersion": "1.2.0",
        \\    "Status": "exited",
        \\    "Running": false,
        \\    "Paused": false,
        \\    "Restarting": false,
        \\    "OOMKilled": false,
        \\    "Dead": false,
        \\    "Pid": 0,
        \\    "ExitCode": 143,
        \\    "Error": "container 1b2001551d16322e8d6b6833548a41dde83b488557deeca44a821ba78fe01656: container is running",
        \\    "StartedAt": "2024-08-14T16:57:56.922221612+02:00",
        \\    "FinishedAt": "2024-08-15T01:33:19.35449134+02:00",
        \\    "CheckpointedAt": "0001-01-01T00:00:00Z",
        \\    "RestoredAt": "0001-01-01T00:00:00Z"
        \\  },
        \\  "Image": "a68bd4c6bc4d33757916b2090886d35992933f0fd53590d3c89340446c0dfb16",
        \\  "ImageDigest": "sha256:0895aa9c53ec01ca630541d060c1dd9e43a03f4eece4b491778ff920604f6ed7",
        \\  "ImageName": "registry.fedoraproject.org/fedora-toolbox:40",
        \\  "OCIRuntime": "crun",
        \\  "ConmonPidFile": "/run/user/1000/containers/overlay-containers/1b2001551d16322e8d6b6833548a41dde83b488557deeca44a821ba78fe01656/userdata/conmon.pid",
        \\  "PidFile": "/run/user/1000/containers/overlay-containers/1b2001551d16322e8d6b6833548a41dde83b488557deeca44a821ba78fe01656/userdata/pidfile",
        \\  "RestartCount": 0,
        \\  "Driver": "overlay",
        \\  "MountLabel": "system_u:object_r:container_file_t:s0:c1022,c1023",
        \\  "ProcessLabel": "",
        \\  "Mounts": [
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/run/user/1000",
        \\      "Destination": "/run/user/1000",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "nosuid",
        \\        "nodev",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rprivate"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/run/avahi-daemon/socket",
        \\      "Destination": "/run/avahi-daemon/socket",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "nosuid",
        \\        "nodev",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rprivate"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/dev",
        \\      "Destination": "/dev",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "nosuid",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rslave"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/etc/profile.d/toolbox.sh",
        \\      "Destination": "/etc/profile.d/toolbox.sh",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "rbind"
        \\      ],
        \\      "RW": false,
        \\      "Propagation": "rprivate"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/usr/bin/toolbox",
        \\      "Destination": "/usr/bin/toolbox",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "rbind"
        \\      ],
        \\      "RW": false,
        \\      "Propagation": "rprivate"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "devpts",
        \\      "Destination": "/dev/pts",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [],
        \\      "RW": true,
        \\      "Propagation": ""
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/run/.heim_org.h5l.kcm-socket",
        \\      "Destination": "/run/.heim_org.h5l.kcm-socket",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "nosuid",
        \\        "nodev",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rprivate"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/run/pcscd/pcscd.comm",
        \\      "Destination": "/run/pcscd/pcscd.comm",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "nosuid",
        \\        "nodev",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rprivate"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/",
        \\      "Destination": "/run/host",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rslave"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/run/dbus/system_bus_socket",
        \\      "Destination": "/run/dbus/system_bus_socket",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "nosuid",
        \\        "nodev",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rprivate"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/var/home/kilian",
        \\      "Destination": "/var/home/kilian",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rslave"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/run/media",
        \\      "Destination": "/run/media",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "nosuid",
        \\        "nodev",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rslave"
        \\    }
        \\  ],
        \\  "Config": {
        \\    "Hostname": "toolbox",
        \\    "Env": [
        \\      "container=oci",
        \\      "TOOLBOX_PATH=/usr/bin/toolbox",
        \\      "XDG_RUNTIME_DIR=/run/user/1000",
        \\      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        \\      "HOSTNAME=toolbox",
        \\      "HOME=/root"
        \\    ],
        \\    "Cmd": [
        \\      "toolbox",
        \\      "--log-level",
        \\      "debug",
        \\      "init-container",
        \\      "--gid",
        \\      "1000",
        \\      "--home",
        \\      "/home/kilian",
        \\      "--shell",
        \\      "/bin/bash",
        \\      "--uid",
        \\      "1000",
        \\      "--user",
        \\      "kilian",
        \\      "--home-link",
        \\      "--media-link",
        \\      "--mnt-link"
        \\    ],
        \\    "Image": "registry.fedoraproject.org/fedora-toolbox:40",
        \\    "Volumes": null,
        \\    "WorkingDir": "/",
        \\    "Entrypoint": null,
        \\    "OnBuild": null,
        \\    "Labels": {
        \\      "com.github.containers.toolbox": "true",
        \\      "io.buildah.version": "1.35.3",
        \\      "license": "MIT",
        \\      "name": "fedora-toolbox",
        \\      "org.opencontainers.image.license": "MIT",
        \\      "org.opencontainers.image.name": "fedora-toolbox",
        \\      "org.opencontainers.image.url": "https://fedoraproject.org/",
        \\      "org.opencontainers.image.vendor": "Fedora Project",
        \\      "org.opencontainers.image.version": "40",
        \\      "vendor": "Fedora Project",
        \\      "version": "40"
        \\    },
        \\    "Annotations": {
        \\      "io.container.manager": "libpod",
        \\      "io.podman.annotations.label": "disable",
        \\      "io.podman.annotations.privileged": "TRUE",
        \\      "org.opencontainers.image.stopSignal": "15",
        \\      "org.systemd.property.KillSignal": "15",
        \\      "org.systemd.property.TimeoutStopUSec": "uint64 10000000"
        \\    },
        \\    "StopSignal": "SIGTERM",
        \\    "HealthcheckOnFailureAction": "none",
        \\    "CreateCommand": [
        \\      "podman",
        \\      "--log-level",
        \\      "error",
        \\      "create",
        \\      "--cgroupns",
        \\      "host",
        \\      "--dns",
        \\      "none",
        \\      "--env",
        \\      "TOOLBOX_PATH=/usr/bin/toolbox",
        \\      "--env",
        \\      "XDG_RUNTIME_DIR=/run/user/1000",
        \\      "--hostname",
        \\      "toolbox",
        \\      "--ipc",
        \\      "host",
        \\      "--label",
        \\      "com.github.containers.toolbox=true",
        \\      "--mount",
        \\      "type=devpts,destination=/dev/pts",
        \\      "--name",
        \\      "systemprogrammierung",
        \\      "--network",
        \\      "host",
        \\      "--no-hosts",
        \\      "--pid",
        \\      "host",
        \\      "--privileged",
        \\      "--security-opt",
        \\      "label=disable",
        \\      "--ulimit",
        \\      "host",
        \\      "--userns",
        \\      "keep-id",
        \\      "--user",
        \\      "root:root",
        \\      "--volume",
        \\      "/:/run/host:rslave",
        \\      "--volume",
        \\      "/dev:/dev:rslave",
        \\      "--volume",
        \\      "/run/dbus/system_bus_socket:/run/dbus/system_bus_socket",
        \\      "--volume",
        \\      "/var/home/kilian:/var/home/kilian:rslave",
        \\      "--volume",
        \\      "/usr/bin/toolbox:/usr/bin/toolbox:ro",
        \\      "--volume",
        \\      "/run/user/1000:/run/user/1000",
        \\      "--volume",
        \\      "/run/avahi-daemon/socket:/run/avahi-daemon/socket",
        \\      "--volume",
        \\      "/run/.heim_org.h5l.kcm-socket:/run/.heim_org.h5l.kcm-socket",
        \\      "--volume",
        \\      "/run/pcscd/pcscd.comm:/run/pcscd/pcscd.comm",
        \\      "--volume",
        \\      "/run/media:/run/media:rslave",
        \\      "--volume",
        \\      "/etc/profile.d/toolbox.sh:/etc/profile.d/toolbox.sh:ro",
        \\      "registry.fedoraproject.org/fedora-toolbox:40",
        \\      "toolbox",
        \\      "--log-level",
        \\      "debug",
        \\      "init-container",
        \\      "--gid",
        \\      "1000",
        \\      "--home",
        \\      "/home/kilian",
        \\      "--shell",
        \\      "/bin/bash",
        \\      "--uid",
        \\      "1000",
        \\      "--user",
        \\      "kilian",
        \\      "--home-link",
        \\      "--media-link",
        \\      "--mnt-link"
        \\    ],
        \\    "Umask": "0022",
        \\    "Timeout": 0,
        \\    "StopTimeout": 10,
        \\    "Passwd": true,
        \\    "sdNotifyMode": "container"
        \\  },
        \\  "HostConfig": {
        \\    "Binds": [
        \\      "/run/user/1000:/run/user/1000:rw,rprivate,nosuid,nodev,rbind",
        \\      "/run/avahi-daemon/socket:/run/avahi-daemon/socket:rw,rprivate,nosuid,nodev,rbind",
        \\      "/dev:/dev:rslave,rw,nosuid,rbind",
        \\      "/etc/profile.d/toolbox.sh:/etc/profile.d/toolbox.sh:ro,rprivate,rbind",
        \\      "/usr/bin/toolbox:/usr/bin/toolbox:ro,rprivate,rbind",
        \\      "devpts:/dev/pts",
        \\      "/run/.heim_org.h5l.kcm-socket:/run/.heim_org.h5l.kcm-socket:rw,rprivate,nosuid,nodev,rbind",
        \\      "/run/pcscd/pcscd.comm:/run/pcscd/pcscd.comm:rw,rprivate,nosuid,nodev,rbind",
        \\      "/:/run/host:rslave,rw,rbind",
        \\      "/run/dbus/system_bus_socket:/run/dbus/system_bus_socket:rw,rprivate,nosuid,nodev,rbind",
        \\      "/var/home/kilian:/var/home/kilian:rslave,rw,rbind",
        \\      "/run/media:/run/media:rslave,rw,nosuid,nodev,rbind"
        \\    ],
        \\    "IDMappings": {
        \\      "UidMap": [
        \\        "0:1:1000",
        \\        "1000:0:1",
        \\        "1001:1001:64536"
        \\      ],
        \\      "GidMap": [
        \\        "0:1:1000",
        \\        "1000:0:1",
        \\        "1001:1001:64536"
        \\      ]
        \\    },
        \\    "Isolation": "",
        \\    "CpuShares": 0,
        \\    "Memory": 0,
        \\    "NanoCpus": 0,
        \\    "CgroupParent": "user.slice",
        \\    "BlkioWeight": 0,
        \\    "BlkioWeightDevice": null,
        \\    "BlkioDeviceReadBps": null,
        \\    "BlkioDeviceWriteBps": null,
        \\    "BlkioDeviceReadIOps": null,
        \\    "BlkioDeviceWriteIOps": null,
        \\    "CpuPeriod": 0,
        \\    "CpuQuota": 0,
        \\    "CpuRealtimePeriod": 0,
        \\    "CpuRealtimeRuntime": 0,
        \\    "CpusetCpus": "",
        \\    "CpusetMems": "",
        \\    "Devices": [],
        \\    "DiskQuota": 0,
        \\    "KernelMemory": 0,
        \\    "MemoryReservation": 0,
        \\    "MemorySwap": 0,
        \\    "MemorySwappiness": 0,
        \\    "OomKillDisable": false,
        \\    "PidsLimit": 2048,
        \\    "Ulimits": [
        \\      {
        \\        "Name": "RLIMIT_NOFILE",
        \\        "Soft": 524288,
        \\        "Hard": 524288
        \\      },
        \\      {
        \\        "Name": "RLIMIT_NPROC",
        \\        "Soft": 126648,
        \\        "Hard": 126648
        \\      }
        \\    ],
        \\    "CpuCount": 0,
        \\    "CpuPercent": 0,
        \\    "IOMaximumIOps": 0,
        \\    "IOMaximumBandwidth": 0,
        \\    "CgroupConf": null
        \\  }
        \\}
    ;
    var parsed = try parseContainer(std.testing.allocator, json);
    defer parsed.deinit();

    const expectEqual = std.testing.expectEqual;
    const expectEqualStrings = std.testing.expectEqualStrings;

    try expectEqualStrings(id, parsed.id);
    try expectEqualStrings(name, parsed.name);
    try expectEqual(state, parsed.state);
    try expectEqual(created.timestamp, parsed.created.timestamp);
    try expectEqual(created.timezone.*, parsed.created.timezone.*);
    try expectEqualStrings(image_id, parsed.image_id);
    try expectEqualStrings(mount0.source, parsed.mounts[0].source);
    try expectEqualStrings(mount0.destination, parsed.mounts[0].destination);
    try expectEqual(mount0.propagation, parsed.mounts[0].propagation);
    try expectEqual(mount0.kind, parsed.mounts[0].kind);
    try expectEqual(mount0.kind.bind.recursive, parsed.mounts[0].kind.bind.recursive);
    try expectEqual(uid0.start_container, parsed.idmappings.uids[0].start_container);
    try expectEqual(uid0.start_host, parsed.idmappings.uids[0].start_host);
    try expectEqual(uid0.amount, parsed.idmappings.uids[0].amount);
    try expectEqual(gid0.start_container, parsed.idmappings.gids[0].start_container);
    try expectEqual(gid0.start_host, parsed.idmappings.gids[0].start_host);
    try expectEqual(gid0.amount, parsed.idmappings.gids[0].amount);
    try expectEqualStrings(hostname, parsed.config.hostname);
    for (cmd, parsed.config.cmd) |expected, actual| {
        try expectEqualStrings(expected, actual);
    }
    try expectEqualStrings(env0_value, parsed.config.env.get(env0_key).?);
    try expectEqualStrings(working_dir, parsed.config.working_dir);
    try expectEqualStrings(label_value, parsed.config.labels.get(label_key).?);
    try expectEqualStrings(annotation_value, parsed.config.annotations.get(annotation_key).?);
    try expectEqual(stop_signal, parsed.config.stop_signal);
    for (create_command, parsed.config.create_command) |expected, actual| {
        try expectEqualStrings(expected, actual);
    }
    try expectEqual(umask, parsed.config.umask);
}

test "full Parse with StopSignal as number" {
    const str =
        \\{
        \\  "Id": "57212d1cd97283b0abd82ddc4cfd043d0c3669cb38d2b48b9d1f6164f5f58e7a",
        \\  "Created": "2024-10-17T01:58:16.963731673+02:00",
        \\  "Path": "/usr/libexec/libnexpod/libnexpodd",
        \\  "Args": [
        \\    "--uid",
        \\    "1000",
        \\    "--user",
        \\    "dev",
        \\    "--shell",
        \\    "/bin/bash",
        \\    "--home",
        \\    "/home/dev",
        \\    "--group",
        \\    "1000=dev",
        \\    "--group",
        \\    "46=plugdev",
        \\    "--group",
        \\    "4=adm",
        \\    "--group",
        \\    "24=cdrom",
        \\    "--group",
        \\    "27=sudo",
        \\    "--group",
        \\    "30=dip",
        \\    "--group",
        \\    "114=lpadmin",
        \\    "--group",
        \\    "100=users"
        \\  ],
        \\  "State": {
        \\    "OciVersion": "1.1.0",
        \\    "Status": "created",
        \\    "Running": false,
        \\    "Paused": false,
        \\    "Restarting": false,
        \\    "OOMKilled": false,
        \\    "Dead": false,
        \\    "Pid": 0,
        \\    "ExitCode": 0,
        \\    "Error": "",
        \\    "StartedAt": "0001-01-01T00:00:00Z",
        \\    "FinishedAt": "0001-01-01T00:00:00Z",
        \\    "Health": {
        \\      "Status": "",
        \\      "FailingStreak": 0,
        \\      "Log": null
        \\    },
        \\    "CheckpointedAt": "0001-01-01T00:00:00Z",
        \\    "RestoredAt": "0001-01-01T00:00:00Z"
        \\  },
        \\  "Image": "43d8a0ddf9c6769ef5f2a17e791299c06bcb7838a27fc91ce5454236116c90f2",
        \\  "ImageDigest": "sha256:244a97eb5826459d3bacf3245f13ab6131434b43b37e70626006903387115084",
        \\  "ImageName": "localhost/libnexpod-test-archlinux:latest",
        \\  "Rootfs": "",
        \\  "Pod": "",
        \\  "ResolvConfPath": "",
        \\  "HostnamePath": "",
        \\  "HostsPath": "",
        \\  "StaticDir": "/home/dev/.local/share/containers/storage/overlay-containers/57212d1cd97283b0abd82ddc4cfd043d0c3669cb38d2b48b9d1f6164f5f58e7a/userdata",
        \\  "OCIRuntime": "crun",
        \\  "ConmonPidFile": "/run/user/1000/containers/overlay-containers/57212d1cd97283b0abd82ddc4cfd043d0c3669cb38d2b48b9d1f6164f5f58e7a/userdata/conmon.pid",
        \\  "PidFile": "/run/user/1000/containers/overlay-containers/57212d1cd97283b0abd82ddc4cfd043d0c3669cb38d2b48b9d1f6164f5f58e7a/userdata/pidfile",
        \\  "Name": "libnexpod-systemtest-create-name-correct",
        \\  "RestartCount": 0,
        \\  "Driver": "overlay",
        \\  "MountLabel": "",
        \\  "ProcessLabel": "",
        \\  "AppArmorProfile": "",
        \\  "EffectiveCaps": [
        \\    "CAP_AUDIT_CONTROL",
        \\    "CAP_AUDIT_READ",
        \\    "CAP_AUDIT_WRITE",
        \\    "CAP_BLOCK_SUSPEND",
        \\    "CAP_BPF",
        \\    "CAP_CHECKPOINT_RESTORE",
        \\    "CAP_CHOWN",
        \\    "CAP_DAC_OVERRIDE",
        \\    "CAP_DAC_READ_SEARCH",
        \\    "CAP_FOWNER",
        \\    "CAP_FSETID",
        \\    "CAP_IPC_LOCK",
        \\    "CAP_IPC_OWNER",
        \\    "CAP_KILL",
        \\    "CAP_LEASE",
        \\    "CAP_LINUX_IMMUTABLE",
        \\    "CAP_MAC_ADMIN",
        \\    "CAP_MAC_OVERRIDE",
        \\    "CAP_MKNOD",
        \\    "CAP_NET_ADMIN",
        \\    "CAP_NET_BIND_SERVICE",
        \\    "CAP_NET_BROADCAST",
        \\    "CAP_NET_RAW",
        \\    "CAP_PERFMON",
        \\    "CAP_SETFCAP",
        \\    "CAP_SETGID",
        \\    "CAP_SETPCAP",
        \\    "CAP_SETUID",
        \\    "CAP_SYSLOG",
        \\    "CAP_SYS_ADMIN",
        \\    "CAP_SYS_BOOT",
        \\    "CAP_SYS_CHROOT",
        \\    "CAP_SYS_MODULE",
        \\    "CAP_SYS_NICE",
        \\    "CAP_SYS_PACCT",
        \\    "CAP_SYS_PTRACE",
        \\    "CAP_SYS_RAWIO",
        \\    "CAP_SYS_RESOURCE",
        \\    "CAP_SYS_TIME",
        \\    "CAP_SYS_TTY_CONFIG",
        \\    "CAP_WAKE_ALARM"
        \\  ],
        \\  "BoundingCaps": [
        \\    "CAP_AUDIT_CONTROL",
        \\    "CAP_AUDIT_READ",
        \\    "CAP_AUDIT_WRITE",
        \\    "CAP_BLOCK_SUSPEND",
        \\    "CAP_BPF",
        \\    "CAP_CHECKPOINT_RESTORE",
        \\    "CAP_CHOWN",
        \\    "CAP_DAC_OVERRIDE",
        \\    "CAP_DAC_READ_SEARCH",
        \\    "CAP_FOWNER",
        \\    "CAP_FSETID",
        \\    "CAP_IPC_LOCK",
        \\    "CAP_IPC_OWNER",
        \\    "CAP_KILL",
        \\    "CAP_LEASE",
        \\    "CAP_LINUX_IMMUTABLE",
        \\    "CAP_MAC_ADMIN",
        \\    "CAP_MAC_OVERRIDE",
        \\    "CAP_MKNOD",
        \\    "CAP_NET_ADMIN",
        \\    "CAP_NET_BIND_SERVICE",
        \\    "CAP_NET_BROADCAST",
        \\    "CAP_NET_RAW",
        \\    "CAP_PERFMON",
        \\    "CAP_SETFCAP",
        \\    "CAP_SETGID",
        \\    "CAP_SETPCAP",
        \\    "CAP_SETUID",
        \\    "CAP_SYSLOG",
        \\    "CAP_SYS_ADMIN",
        \\    "CAP_SYS_BOOT",
        \\    "CAP_SYS_CHROOT",
        \\    "CAP_SYS_MODULE",
        \\    "CAP_SYS_NICE",
        \\    "CAP_SYS_PACCT",
        \\    "CAP_SYS_PTRACE",
        \\    "CAP_SYS_RAWIO",
        \\    "CAP_SYS_RESOURCE",
        \\    "CAP_SYS_TIME",
        \\    "CAP_SYS_TTY_CONFIG",
        \\    "CAP_WAKE_ALARM"
        \\  ],
        \\  "ExecIDs": [],
        \\  "GraphDriver": {
        \\    "Name": "overlay",
        \\    "Data": {
        \\      "LowerDir": "/home/dev/.local/share/containers/storage/overlay/29a680b0297df7dbdc38074769e00916c8938f166d53a6821333cd11ecf235f5/diff:/home/dev/.local/share/containers/storage/overlay/d6c73580dcd0c999232e1082b89adcb51a18fd2f9cb8d145e398ddb88f780cb3/diff:/home/dev/.local/share/containers/storage/overlay/9b035e9cf3608d1ebfeb5a0989e8a0ceafe142db49c4fd651e925e6c8a60b88e/diff:/home/dev/.local/share/containers/storage/overlay/f4c8caf84c436d04cfe6855a421999b93c21655270210959b0a6e70487b6438f/diff:/home/dev/.local/share/containers/storage/overlay/79f3c2e170d06ba98d60a8af91c76890f68b4a45d6ab2e7288cbc74228c2a639/diff",
        \\      "UpperDir": "/home/dev/.local/share/containers/storage/overlay/ebe2074bba9a0c00a608b18be3bbca6f2083b11c47b37925d387a77464083984/diff",
        \\      "WorkDir": "/home/dev/.local/share/containers/storage/overlay/ebe2074bba9a0c00a608b18be3bbca6f2083b11c47b37925d387a77464083984/work"
        \\    }
        \\  },
        \\  "Mounts": [
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/etc/hosts",
        \\      "Destination": "/etc/hosts",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "rbind"
        \\      ],
        \\      "RW": false,
        \\      "Propagation": "rprivate"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/run/systemd/resolve",
        \\      "Destination": "/run/systemd/resolve",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "exec",
        \\        "nosuid",
        \\        "nodev",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rslave"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/etc/host.conf",
        \\      "Destination": "/etc/host.conf",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "rbind"
        \\      ],
        \\      "RW": false,
        \\      "Propagation": "rprivate"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/srv",
        \\      "Destination": "/srv",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "exec",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rslave"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/sys",
        \\      "Destination": "/sys",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "noexec",
        \\        "nosuid",
        \\        "nodev",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rslave"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/mnt",
        \\      "Destination": "/mnt",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "exec",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rslave"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/opt",
        \\      "Destination": "/opt",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "exec",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rslave"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/run/systemd/users",
        \\      "Destination": "/run/systemd/users",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "exec",
        \\        "nosuid",
        \\        "nodev",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rslave"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/media",
        \\      "Destination": "/media",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "exec",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rslave"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/run/udev",
        \\      "Destination": "/run/udev",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "exec",
        \\        "nosuid",
        \\        "nodev",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rslave"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/run/user/1000",
        \\      "Destination": "/run/user/1000",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "exec",
        \\        "nosuid",
        \\        "nodev",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rshared"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/",
        \\      "Destination": "/run/host",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "exec",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rslave"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/var/opt",
        \\      "Destination": "/var/opt",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "exec",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rslave"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/run/systemd/sessions",
        \\      "Destination": "/run/systemd/sessions",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "exec",
        \\        "nosuid",
        \\        "nodev",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rslave"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/var/run/dbus/system_bus_socket",
        \\      "Destination": "/var/run/dbus/system_bus_socket",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "bind",
        \\        "noexec",
        \\        "nosuid",
        \\        "nodev"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rprivate"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/run/avahi-daemon/socket",
        \\      "Destination": "/run/avahi-daemon/socket",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "bind",
        \\        "noexec",
        \\        "nosuid",
        \\        "nodev"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rprivate"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/etc/hostname",
        \\      "Destination": "/etc/hostname",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "bind"
        \\      ],
        \\      "RW": false,
        \\      "Propagation": "rprivate"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/run/systemd/journal",
        \\      "Destination": "/run/systemd/journal",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "exec",
        \\        "nosuid",
        \\        "nodev",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rslave"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/tmp",
        \\      "Destination": "/tmp",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rslave"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/var/log/journal",
        \\      "Destination": "/var/log/journal",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "bind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rprivate"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/home",
        \\      "Destination": "/home",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "exec",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rslave"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/home/dev",
        \\      "Destination": "/home/dev",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "exec",
        \\        "suid",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rshared"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/etc/resolv.conf",
        \\      "Destination": "/etc/resolv.conf",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "bind",
        \\        "noexec",
        \\        "nosuid",
        \\        "nodev"
        \\      ],
        \\      "RW": false,
        \\      "Propagation": "rprivate"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/etc/machine-id",
        \\      "Destination": "/etc/machine-id",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "bind",
        \\        "exec"
        \\      ],
        \\      "RW": false,
        \\      "Propagation": "rprivate"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/dev",
        \\      "Destination": "/dev",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "dev",
        \\        "exec",
        \\        "nosuid",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rslave"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/var/lib/systemd/coredump",
        \\      "Destination": "/var/lib/systemd/coredump",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "bind",
        \\        "exec"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rprivate"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/home/dev/libnexpod/.zig-cache/o/49cb0df229fbf0302f504c1fa9693f47/libnexpodd",
        \\      "Destination": "/usr/libexec/libnexpod/libnexpodd",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "bind",
        \\        "exec"
        \\      ],
        \\      "RW": false,
        \\      "Propagation": "rprivate"
        \\    },
        \\    {
        \\      "Type": "bind",
        \\      "Source": "/run/systemd/system",
        \\      "Destination": "/run/systemd/system",
        \\      "Driver": "",
        \\      "Mode": "",
        \\      "Options": [
        \\        "exec",
        \\        "nosuid",
        \\        "nodev",
        \\        "rbind"
        \\      ],
        \\      "RW": true,
        \\      "Propagation": "rslave"
        \\    }
        \\  ],
        \\  "Dependencies": [],
        \\  "NetworkSettings": {
        \\    "EndpointID": "",
        \\    "Gateway": "",
        \\    "IPAddress": "",
        \\    "IPPrefixLen": 0,
        \\    "IPv6Gateway": "",
        \\    "GlobalIPv6Address": "",
        \\    "GlobalIPv6PrefixLen": 0,
        \\    "MacAddress": "",
        \\    "Bridge": "",
        \\    "SandboxID": "",
        \\    "HairpinMode": false,
        \\    "LinkLocalIPv6Address": "",
        \\    "LinkLocalIPv6PrefixLen": 0,
        \\    "Ports": {},
        \\    "SandboxKey": "",
        \\    "Networks": {
        \\      "host": {
        \\        "EndpointID": "",
        \\        "Gateway": "",
        \\        "IPAddress": "",
        \\        "IPPrefixLen": 0,
        \\        "IPv6Gateway": "",
        \\        "GlobalIPv6Address": "",
        \\        "GlobalIPv6PrefixLen": 0,
        \\        "MacAddress": "",
        \\        "NetworkID": "host",
        \\        "DriverOpts": null,
        \\        "IPAMConfig": null,
        \\        "Links": null
        \\      }
        \\    }
        \\  },
        \\  "Namespace": "",
        \\  "IsInfra": false,
        \\  "IsService": false,
        \\  "KubeExitCodePropagation": "invalid",
        \\  "lockNumber": 13,
        \\  "Config": {
        \\    "Hostname": "dev-ubuntu",
        \\    "Domainname": "",
        \\    "User": "root:root",
        \\    "AttachStdin": false,
        \\    "AttachStdout": false,
        \\    "AttachStderr": false,
        \\    "Tty": false,
        \\    "OpenStdin": false,
        \\    "StdinOnce": false,
        \\    "Env": [
        \\      "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        \\      "container=podman",
        \\      "LANG=C.UTF-8",
        \\      "HOME=/home/dev",
        \\      "XDG_RUNTIME_DIR=/run/user/1000"
        \\    ],
        \\    "Cmd": [
        \\      "/usr/libexec/libnexpod/libnexpodd",
        \\      "--uid",
        \\      "1000",
        \\      "--user",
        \\      "dev",
        \\      "--shell",
        \\      "/bin/bash",
        \\      "--home",
        \\      "/home/dev",
        \\      "--group",
        \\      "1000=dev",
        \\      "--group",
        \\      "46=plugdev",
        \\      "--group",
        \\      "4=adm",
        \\      "--group",
        \\      "24=cdrom",
        \\      "--group",
        \\      "27=sudo",
        \\      "--group",
        \\      "30=dip",
        \\      "--group",
        \\      "114=lpadmin",
        \\      "--group",
        \\      "100=users"
        \\    ],
        \\    "Image": "localhost/libnexpod-test-archlinux:latest",
        \\    "Volumes": null,
        \\    "WorkingDir": "/",
        \\    "Entrypoint": "",
        \\    "OnBuild": null,
        \\    "Labels": {
        \\      "com.github.libnexpod": "libnexpod-systemtest",
        \\      "io.buildah.version": "1.33.7",
        \\      "maintainer": "Kilian Hanich <khanich.opensource@gmx.de>",
        \\      "org.opencontainers.image.authors": "Santiago Torres-Arias <santiago@archlinux.org> (@SantiagoTorres), Christian Rebischke <Chris.Rebischke@archlinux.org> (@shibumi), Justin Kromlinger <hashworks@archlinux.org> (@hashworks)",
        \\      "org.opencontainers.image.created": "2024-10-13T00:07:34+00:00",
        \\      "org.opencontainers.image.description": "Official containerd image of Arch Linux, a simple, lightweight Linux distribution aimed for flexibility.",
        \\      "org.opencontainers.image.documentation": "https://wiki.archlinux.org/title/Docker#Arch_Linux",
        \\      "org.opencontainers.image.licenses": "GPL-3.0-or-later",
        \\      "org.opencontainers.image.revision": "61cb892bfc251e46f73e716ceb3b903ec4e9e725",
        \\      "org.opencontainers.image.source": "https://gitlab.archlinux.org/archlinux/archlinux-docker",
        \\      "org.opencontainers.image.title": "Arch Linux base Image",
        \\      "org.opencontainers.image.url": "https://gitlab.archlinux.org/archlinux/archlinux-docker/-/blob/master/README.md",
        \\      "org.opencontainers.image.version": "20241013.0.269705",
        \\      "summary": "Base Image for Creating Arch Linux libnexpod Containers",
        \\      "usage": "This is meant to be used by the libnexpod library and tools based on it."
        \\    },
        \\    "Annotations": {
        \\      "io.podman.annotations.label": "disable",
        \\      "io.podman.annotations.privileged": "TRUE"
        \\    },
        \\    "StopSignal": 15,
        \\    "HealthcheckOnFailureAction": "none",
        \\    "CreateCommand": [
        \\      "podman",
        \\      "create",
        \\      "--cgroupns",
        \\      "host",
        \\      "--dns",
        \\      "none",
        \\      "--ipc",
        \\      "host",
        \\      "--network",
        \\      "host",
        \\      "--no-hosts",
        \\      "--pid",
        \\      "host",
        \\      "--privileged",
        \\      "--security-opt",
        \\      "label=disable",
        \\      "--ulimit",
        \\      "host",
        \\      "--userns",
        \\      "keep-id",
        \\      "--user",
        \\      "root:root",
        \\      "--name",
        \\      "libnexpod-systemtest-create-name-correct",
        \\      "--env",
        \\      "HOME=/home/dev",
        \\      "--env",
        \\      "XDG_RUNTIME_DIR=/run/user/1000",
        \\      "--label",
        \\      "com.github.libnexpod=libnexpod-systemtest",
        \\      "--mount=type=bind,bind-nonrecursive,source=/etc/resolv.conf,destination=/etc/resolv.conf,ro=true",
        \\      "--mount=type=bind,source=/etc/hosts,destination=/etc/hosts,ro=true",
        \\      "--mount=type=bind,source=/etc/host.conf,destination=/etc/host.conf,ro=true",
        \\      "--mount=type=bind,bind-nonrecursive,source=/etc/hostname,destination=/etc/hostname,ro=true",
        \\      "--mount=type=bind,bind-nonrecursive,source=/etc/machine-id,destination=/etc/machine-id,ro=true,exec",
        \\      "--mount=type=bind,source=/,destination=/run/host/,ro=false,exec,rslave",
        \\      "--mount=type=bind,source=/tmp,destination=/tmp,ro=false,rslave",
        \\      "--mount=type=bind,source=/dev,destination=/dev,ro=false,dev,exec,rslave",
        \\      "--mount=type=bind,source=/sys,destination=/sys,ro=false,rslave",
        \\      "--mount=type=bind,bind-nonrecursive,source=/var/log/journal,destination=/var/log/journal,ro=false",
        \\      "--mount=type=bind,bind-nonrecursive,source=/var/lib/systemd/coredump,destination=/var/lib/systemd/coredump,ro=false,exec,rprivate",
        \\      "--mount=type=bind,source=/mnt,destination=/mnt,ro=false,exec,rslave",
        \\      "--mount=type=bind,source=/opt,destination=/opt,ro=false,exec,rslave",
        \\      "--mount=type=bind,source=/var/opt,destination=/var/opt,ro=false,exec,rslave",
        \\      "--mount=type=bind,source=/srv,destination=/srv,ro=false,exec,rslave",
        \\      "--mount=type=bind,source=/home,destination=/home,ro=false,exec,rslave",
        \\      "--mount=type=bind,source=/run/systemd/journal,destination=/run/systemd/journal,ro=false,exec,rslave",
        \\      "--mount=type=bind,source=/run/systemd/resolve,destination=/run/systemd/resolve,ro=false,exec,rslave",
        \\      "--mount=type=bind,source=/run/systemd/sessions,destination=/run/systemd/sessions,ro=false,exec,rslave",
        \\      "--mount=type=bind,source=/run/systemd/system,destination=/run/systemd/system,ro=false,exec,rslave",
        \\      "--mount=type=bind,source=/run/systemd/users,destination=/run/systemd/users,ro=false,exec,rslave",
        \\      "--mount=type=bind,source=/media,destination=/media,ro=false,exec,rslave",
        \\      "--mount=type=bind,source=/run/udev,destination=/run/udev,ro=false,exec,rslave",
        \\      "--mount=type=bind,bind-nonrecursive,source=/var/run/dbus/system_bus_socket,destination=/var/run/dbus/system_bus_socket,ro=false,rprivate",
        \\      "--mount=type=bind,source=/home/dev,destination=/home/dev,ro=false,exec,suid,rshared",
        \\      "--mount=type=bind,source=/run/user/1000,destination=/run/user/1000,ro=false,exec,rshared",
        \\      "--mount=type=bind,bind-nonrecursive,source=/run/avahi-daemon/socket,destination=/run/avahi-daemon/socket,ro=false",
        \\      "--mount=type=bind,bind-nonrecursive,source=/home/dev/libnexpod/.zig-cache/o/49cb0df229fbf0302f504c1fa9693f47/libnexpodd,destination=/usr/libexec/libnexpod/libnexpodd,ro=true,exec",
        \\      "43d8a0ddf9c6769ef5f2a17e791299c06bcb7838a27fc91ce5454236116c90f2",
        \\      "/usr/libexec/libnexpod/libnexpodd",
        \\      "--uid",
        \\      "1000",
        \\      "--user",
        \\      "dev",
        \\      "--shell",
        \\      "/bin/bash",
        \\      "--home",
        \\      "/home/dev",
        \\      "--group",
        \\      "1000=dev",
        \\      "--group",
        \\      "46=plugdev",
        \\      "--group",
        \\      "4=adm",
        \\      "--group",
        \\      "24=cdrom",
        \\      "--group",
        \\      "27=sudo",
        \\      "--group",
        \\      "30=dip",
        \\      "--group",
        \\      "114=lpadmin",
        \\      "--group",
        \\      "100=users"
        \\    ],
        \\    "Umask": "0022",
        \\    "Timeout": 0,
        \\    "StopTimeout": 10,
        \\    "Passwd": true,
        \\    "sdNotifyMode": "container"
        \\  },
        \\  "HostConfig": {
        \\    "Binds": [
        \\      "/etc/hosts:/etc/hosts:ro,rprivate,rbind",
        \\      "/run/systemd/resolve:/run/systemd/resolve:exec,rslave,rw,nosuid,nodev,rbind",
        \\      "/etc/host.conf:/etc/host.conf:ro,rprivate,rbind",
        \\      "/srv:/srv:exec,rslave,rw,rbind",
        \\      "/sys:/sys:rslave,rw,noexec,nosuid,nodev,rbind",
        \\      "/mnt:/mnt:exec,rslave,rw,rbind",
        \\      "/opt:/opt:exec,rslave,rw,rbind",
        \\      "/run/systemd/users:/run/systemd/users:exec,rslave,rw,nosuid,nodev,rbind",
        \\      "/media:/media:exec,rslave,rw,rbind",
        \\      "/run/udev:/run/udev:exec,rslave,rw,nosuid,nodev,rbind",
        \\      "/run/user/1000:/run/user/1000:exec,rshared,rw,nosuid,nodev,rbind",
        \\      "/:/run/host:exec,rslave,rw,rbind",
        \\      "/var/opt:/var/opt:exec,rslave,rw,rbind",
        \\      "/run/systemd/sessions:/run/systemd/sessions:exec,rslave,rw,nosuid,nodev,rbind",
        \\      "/var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket:bind,rprivate,rw,noexec,nosuid,nodev",
        \\      "/run/avahi-daemon/socket:/run/avahi-daemon/socket:bind,rw,rprivate,noexec,nosuid,nodev",
        \\      "/etc/hostname:/etc/hostname:bind,ro,rprivate",
        \\      "/run/systemd/journal:/run/systemd/journal:exec,rslave,rw,nosuid,nodev,rbind",
        \\      "/tmp:/tmp:rslave,rw,rbind",
        \\      "/var/log/journal:/var/log/journal:bind,rw,rprivate",
        \\      "/home:/home:exec,rslave,rw,rbind",
        \\      "/home/dev:/home/dev:exec,suid,rshared,rw,rbind",
        \\      "/etc/resolv.conf:/etc/resolv.conf:bind,ro,rprivate,noexec,nosuid,nodev",
        \\      "/etc/machine-id:/etc/machine-id:bind,ro,exec,rprivate",
        \\      "/dev:/dev:dev,exec,rslave,rw,nosuid,rbind",
        \\      "/var/lib/systemd/coredump:/var/lib/systemd/coredump:bind,exec,rprivate,rw",
        \\      "/home/dev/libnexpod/.zig-cache/o/49cb0df229fbf0302f504c1fa9693f47/libnexpodd:/usr/libexec/libnexpod/libnexpodd:bind,ro,exec,rprivate",
        \\      "/run/systemd/system:/run/systemd/system:exec,rslave,rw,nosuid,nodev,rbind"
        \\    ],
        \\    "CgroupManager": "systemd",
        \\    "CgroupMode": "host",
        \\    "ContainerIDFile": "",
        \\    "LogConfig": {
        \\      "Type": "journald",
        \\      "Config": null,
        \\      "Path": "",
        \\      "Tag": "",
        \\      "Size": "0B"
        \\    },
        \\    "NetworkMode": "host",
        \\    "PortBindings": {},
        \\    "RestartPolicy": {
        \\      "Name": "",
        \\      "MaximumRetryCount": 0
        \\    },
        \\    "AutoRemove": false,
        \\    "VolumeDriver": "",
        \\    "VolumesFrom": null,
        \\    "CapAdd": [],
        \\    "CapDrop": [],
        \\    "Dns": [],
        \\    "DnsOptions": [],
        \\    "DnsSearch": [],
        \\    "ExtraHosts": [],
        \\    "GroupAdd": [],
        \\    "IpcMode": "host",
        \\    "Cgroup": "",
        \\    "Cgroups": "default",
        \\    "Links": null,
        \\    "OomScoreAdj": 0,
        \\    "PidMode": "host",
        \\    "Privileged": true,
        \\    "PublishAllPorts": false,
        \\    "ReadonlyRootfs": false,
        \\    "SecurityOpt": [
        \\      "label=disable",
        \\      "unmask=all"
        \\    ],
        \\    "Tmpfs": {},
        \\    "UTSMode": "private",
        \\    "UsernsMode": "private",
        \\    "IDMappings": {
        \\      "UidMap": [
        \\        "0:1:1000",
        \\        "1000:0:1",
        \\        "1001:1001:64536"
        \\      ],
        \\      "GidMap": [
        \\        "0:1:1000",
        \\        "1000:0:1",
        \\        "1001:1001:64536"
        \\      ]
        \\    },
        \\    "ShmSize": 65536000,
        \\    "Runtime": "oci",
        \\    "ConsoleSize": [
        \\      0,
        \\      0
        \\    ],
        \\    "Isolation": "",
        \\    "CpuShares": 0,
        \\    "Memory": 0,
        \\    "NanoCpus": 0,
        \\    "CgroupParent": "user.slice",
        \\    "BlkioWeight": 0,
        \\    "BlkioWeightDevice": null,
        \\    "BlkioDeviceReadBps": null,
        \\    "BlkioDeviceWriteBps": null,
        \\    "BlkioDeviceReadIOps": null,
        \\    "BlkioDeviceWriteIOps": null,
        \\    "CpuPeriod": 0,
        \\    "CpuQuota": 0,
        \\    "CpuRealtimePeriod": 0,
        \\    "CpuRealtimeRuntime": 0,
        \\    "CpusetCpus": "",
        \\    "CpusetMems": "",
        \\    "Devices": [],
        \\    "DiskQuota": 0,
        \\    "KernelMemory": 0,
        \\    "MemoryReservation": 0,
        \\    "MemorySwap": 0,
        \\    "MemorySwappiness": 0,
        \\    "OomKillDisable": false,
        \\    "PidsLimit": 2048,
        \\    "Ulimits": [],
        \\    "CpuCount": 0,
        \\    "CpuPercent": 0,
        \\    "IOMaximumIOps": 0,
        \\    "IOMaximumBandwidth": 0,
        \\    "CgroupConf": null
        \\  }
        \\}
    ;
    var parsed = try parseContainer(std.testing.allocator, str);
    defer parsed.deinit();
}
