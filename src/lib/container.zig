const std = @import("std");
const builtin = @import("builtin");
const log = @import("logging");
const zeit = @import("zeit");
const podman = @import("podman.zig");
const errors = @import("errors.zig");

/// The current Run State a container can be in.
pub const State = enum {
    Exited,
    Running,
    Created,
    Unknown,
};

/// The way mount propagation is handled.
pub const PropagationOptions = enum {
    shared,
    rshared,
    slave,
    rslave,
    private,
    rprivate,
    unbindable,
    runbindable,
    none,
};

/// The description of a Mount as expected and given by Podman in a parsed way.
pub const Mount = struct {
    source: []const u8,
    destination: []const u8,
    kind: union(enum) {
        volume: struct {
            name: []const u8,
        },
        bind: struct {
            recursive: bool = false,
        },
        devpts: struct {},
    },
    propagation: PropagationOptions,
    options: struct {
        suid: bool = false,
        dev: bool = false,
        exec: bool = true,
        rw: bool,
    },
};

/// A description of the mapping between the different IDs between host and container.
/// `start_container` describes with which ID the map starts on the container side.
/// `start_host` describes with which ID the map starts on the host side.
/// `amount` is the amount of IDs which get mapped.
pub fn IdMapping(kind: type) type {
    return struct {
        start_container: kind,
        start_host: kind,
        amount: usize,
    };
}

/// A collection of configuration information of a given container.
pub const ContainerConfig = struct {
    hostname: []const u8,
    cmd: []const []const u8,
    env: std.process.EnvMap,
    working_dir: []const u8,
    labels: std.StringHashMapUnmanaged([]const u8),
    annotations: std.StringHashMapUnmanaged([]const u8),
    stop_signal: i32,
    create_command: []const []const u8,
    umask: std.posix.mode_t,
};

/// The handle to a libnexpod container with either minimal or full information amount.
/// You must call deinit to free the used resources.
pub const Container = union(enum) {
    minimal: struct {
        allocator: std.mem.Allocator,
        id: []const u8,
        name: []const u8,
        state: State,
        created: zeit.Instant,
    },
    full: struct {
        arena: std.heap.ArenaAllocator,
        id: []const u8,
        name: []const u8,
        state: State,
        created: zeit.Instant,
        image_id: []const u8,
        mounts: []const Mount,
        idmappings: struct {
            uids: []const IdMapping(std.posix.uid_t),
            gids: []const IdMapping(std.posix.gid_t),
        },
        config: ContainerConfig,
    },

    /// Frees all resources of this handle.
    pub fn deinit(self: Container) void {
        switch (self) {
            .minimal => |this| {
                this.allocator.free(this.id);
                this.allocator.free(this.name);
            },
            .full => |this| {
                this.arena.deinit();
            },
        }
    }

    /// Gets the current `State` of container regardless of information amount.
    pub fn getStatus(self: Container) State {
        switch (self) {
            .minimal => |this| return this.state,
            .full => |this| return this.state,
        }
    }

    /// Starts a command inside of the container.
    /// It gives you the handle to the child process and the argv which was used for it which you must free manually with the given allocator (each argument and the whole slice).
    /// You can influence the way this command is spawned with the `args` struct.
    /// The caller owns all parameters.
    pub fn runCommand(self: Container, args: struct {
        allocator: std.mem.Allocator,
        argv: []const []const u8,
        env: ?*std.process.EnvMap = null,
        stdin_behaviour: std.process.Child.StdIo,
        stdout_behaviour: std.process.Child.StdIo,
        stderr_behaviour: std.process.Child.StdIo,
        working_dir: []const u8,
    }) errors.RunCommandErrors!struct { std.process.Child, []const []const u8 } {
        if (self.getStatus() != .Running) {
            return error.ContainerNotRunning;
        }

        var env = if (args.env != null)
            args.env.?.*
        else
            try std.process.getEnvMap(args.allocator);
        defer if (args.env == null) {
            env.deinit();
        };

        const ttyNeeded = args.stdin_behaviour == .Inherit and args.stdout_behaviour == .Inherit and std.io.getStdIn().isTty() and std.io.getStdOut().isTty();

        const username = try getUserName(args.allocator);
        defer args.allocator.free(username);

        const argv = try podman.createRunArgs(args.allocator, self.getId(), args.argv, ttyNeeded, env, args.working_dir, username);
        errdefer {
            for (argv) |e| {
                args.allocator.free(e);
            }
            args.allocator.free(argv);
        }

        var process = std.process.Child.init(argv, args.allocator);
        process.stdin_behavior = args.stdin_behaviour;
        process.stdout_behavior = args.stdout_behaviour;
        process.stderr_behavior = args.stderr_behaviour;
        process.env_map = args.env;

        try process.spawn();
        return .{ process, argv };
    }

    /// Updates the information about the container and leaves it afterswards always in full information state.
    pub fn updateInfo(self: *Container) errors.UpdateErrors!void {
        const id = self.getId();
        const allocator = self.getAllocator();
        const json = try podman.getContainerJSON(allocator, id);
        defer allocator.free(json);
        var parsed = try std.json.parseFromSlice(Container, allocator, json, .{});
        defer parsed.deinit();
        const new = try parsed.value.copy(allocator);
        self.deinit();
        self.* = new;
    }

    /// Deletes the container from disk. Use `force = true` if you want to delete it even if it currently running.
    /// It does free the resources of this handle.
    pub fn delete(self: *Container, force: bool) (std.process.Child.RunError || errors.PodmanErrors)!void {
        const id = self.getId();
        const allocator = self.getAllocator();
        try podman.deleteContainer(allocator, id, force);
    }

    /// Tries to starts the container. The handle information will be updated afterwards.
    pub fn start(self: *Container) errors.UpdateErrors!void {
        const id = self.getId();
        const allocator = self.getAllocator();
        // podman sadly doesn't tell us if the container succeeded in starting or immediately died
        // so we instead need to ask for it manually
        try podman.startContainer(allocator, id);
        try self.updateInfo();
    }

    /// Tries to stop the container. The handle information will be updated afterwards.
    pub fn stop(self: *Container) errors.UpdateErrors!void {
        const id = self.getId();
        const allocator = self.getAllocator();
        try podman.stopContainer(allocator, id);
        try self.updateInfo();
    }

    /// Gets the ID of the container regardless of information amount.
    pub fn getId(self: Container) []const u8 {
        switch (self) {
            .minimal => |this| return this.id,
            .full => |this| return this.id,
        }
    }

    /// Turn the amount of information of this handle from minimal to full.
    /// If it is already full, this is a NOOP.
    pub fn makeFull(self: *Container) errors.UpdateErrors!void {
        switch (self.*) {
            .full => {},
            .minimal => try self.updateInfo(),
        }
    }

    /// Creates a copy of this handle with allocator given to this function in whatever information state it currently is.
    pub fn copy(self: Container, allocator: std.mem.Allocator) std.mem.Allocator.Error!Container {
        switch (self) {
            .minimal => |this| {
                const id = try allocator.dupe(u8, this.id);
                errdefer allocator.free(id);
                const name = try allocator.dupe(u8, this.name);
                return .{
                    .minimal = .{
                        .allocator = allocator,
                        .id = id,
                        .name = name,
                        .state = this.state,
                        .created = this.created,
                    },
                };
            },
            .full => |this| {
                var arena = std.heap.ArenaAllocator.init(allocator);
                errdefer arena.deinit();
                const arena_allocator = arena.allocator();
                const id = try arena_allocator.dupe(u8, this.id);
                const name = try arena_allocator.dupe(u8, this.name);
                const image_id = try arena_allocator.dupe(u8, this.image_id);
                var mounts = try arena_allocator.alloc(Mount, this.mounts.len);
                for (this.mounts, 0..) |e, i| {
                    const destination = try arena_allocator.dupe(u8, e.destination);
                    const source = try arena_allocator.dupe(u8, e.source);
                    const kind = val: {
                        switch (e.kind) {
                            .devpts, .bind => break :val e.kind,
                            .volume => {
                                var clone = e.kind;
                                clone.volume.name = try arena_allocator.dupe(u8, e.kind.volume.name);
                                break :val clone;
                            },
                        }
                    };
                    mounts[i] = .{
                        .destination = destination,
                        .source = source,
                        .kind = kind,
                        .options = e.options,
                        .propagation = e.propagation,
                    };
                }
                var uids = try arena_allocator.alloc(IdMapping(std.posix.uid_t), this.idmappings.uids.len);
                for (this.idmappings.uids, 0..) |e, i| {
                    uids[i] = e;
                }
                var gids = try arena_allocator.alloc(IdMapping(std.posix.gid_t), this.idmappings.gids.len);
                for (this.idmappings.gids, 0..) |e, i| {
                    gids[i] = e;
                }
                const hostname = try arena_allocator.dupe(u8, this.config.hostname);
                var cmd = try arena_allocator.alloc([]const u8, this.config.cmd.len);
                for (this.config.cmd, 0..) |e, i| {
                    cmd[i] = try arena_allocator.dupe(u8, e);
                }
                const working_dir = try arena_allocator.dupe(u8, this.config.working_dir);
                var env = std.process.EnvMap.init(arena_allocator);
                var env_iter = this.config.env.iterator();
                while (env_iter.next()) |entry| {
                    try env.put(entry.key_ptr.*, entry.value_ptr.*);
                }
                var labels = std.StringHashMapUnmanaged([]const u8){};
                var labels_iter = this.config.labels.iterator();
                while (labels_iter.next()) |entry| {
                    const key = try arena_allocator.dupe(u8, entry.key_ptr.*);
                    const value = try arena_allocator.dupe(u8, entry.value_ptr.*);
                    try labels.put(arena_allocator, key, value);
                }
                var annotations = std.StringHashMapUnmanaged([]const u8){};
                var annotations_iter = annotations.iterator();
                while (annotations_iter.next()) |entry| {
                    const key = try arena_allocator.dupe(u8, entry.key_ptr.*);
                    const value = try arena_allocator.dupe(u8, entry.value_ptr.*);
                    try annotations.put(arena_allocator, key, value);
                }
                var create_command = try arena_allocator.alloc([]const u8, this.config.create_command.len);
                for (this.config.create_command, 0..) |e, i| {
                    create_command[i] = try arena_allocator.dupe(u8, e);
                }
                return .{
                    .full = .{
                        .arena = arena,
                        .id = id,
                        .name = name,
                        .state = this.state,
                        .created = this.created,
                        .image_id = image_id,
                        .mounts = mounts,
                        .idmappings = .{
                            .uids = uids,
                            .gids = gids,
                        },
                        .config = .{
                            .hostname = hostname,
                            .cmd = cmd,
                            .env = env,
                            .working_dir = working_dir,
                            .labels = labels,
                            .annotations = annotations,
                            .stop_signal = this.config.stop_signal,
                            .create_command = create_command,
                            .umask = this.config.umask,
                        },
                    },
                };
            },
        }
    }

    /// This function is intended to be used by the std.json parsing framework and is leaky.
    pub fn jsonParse(allocator: std.mem.Allocator, scanner_or_reader: anytype, options: std.json.ParseOptions) (std.json.ParseError(@TypeOf(scanner_or_reader.*)) || std.mem.Allocator.Error)!Container {
        const parsed = try std.json.parseFromTokenSourceLeaky(ContainerMarshall, allocator, scanner_or_reader, .{
            .allocate = options.allocate,
            .duplicate_field_behavior = options.duplicate_field_behavior,
            .max_value_len = options.max_value_len,
            // overwrite the given behaviour for unknown fields since we don't want all fields
            .ignore_unknown_fields = true,
        });

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();

        const labels = val: {
            switch (parsed.Config.Labels) {
                .object => |Labels| {
                    var labels = std.StringHashMapUnmanaged([]const u8){};
                    var iter = Labels.iterator();
                    while (iter.next()) |entry| {
                        if (entry.value_ptr.* != .string) {
                            return std.json.ParseFromValueError.UnexpectedToken;
                        }
                        const key = entry.key_ptr.*;
                        const value = entry.value_ptr.*.string;
                        try labels.put(arena_allocator, key, value);
                    }
                    break :val labels;
                },
                else => return std.json.ParseFromValueError.UnexpectedToken,
            }
        };

        const annotations = val: {
            switch (parsed.Config.Annotations) {
                .object => |Annotations| {
                    var annotations = std.StringHashMapUnmanaged([]const u8){};
                    var iter = Annotations.iterator();
                    while (iter.next()) |entry| {
                        if (entry.value_ptr.* != .string) {
                            return std.json.ParseFromValueError.UnexpectedToken;
                        }
                        const key = entry.key_ptr.*;
                        const value = entry.value_ptr.*.string;
                        try annotations.put(arena_allocator, key, value);
                    }
                    break :val annotations;
                },
                else => return std.json.ParseFromValueError.UnexpectedToken,
            }
        };

        var env = std.process.EnvMap.init(arena_allocator);
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
            switch (options.duplicate_field_behavior) {
                .@"error" => if (env.hash_map.contains(key)) {
                    return std.json.ParseFromValueError.DuplicateField;
                } else {
                    try env.put(key, value);
                },
                .use_first => if (!env.hash_map.contains(key)) {
                    try env.put(key, value);
                },
                .use_last => try env.put(key, value),
            }
        }

        var mounts = try arena_allocator.alloc(Mount, parsed.Mounts.len);
        for (parsed.Mounts, 0..) |e, i| {
            const propagation = val: {
                if (std.mem.eql(u8, "shared", e.Propagation)) {
                    break :val PropagationOptions.shared;
                } else if (std.mem.eql(u8, "rshared", e.Propagation)) {
                    break :val PropagationOptions.rshared;
                } else if (std.mem.eql(u8, "slave", e.Propagation)) {
                    break :val PropagationOptions.slave;
                } else if (std.mem.eql(u8, "rslave", e.Propagation)) {
                    break :val PropagationOptions.rslave;
                } else if (std.mem.eql(u8, "private", e.Propagation)) {
                    break :val PropagationOptions.private;
                } else if (std.mem.eql(u8, "rprivate", e.Propagation)) {
                    break :val PropagationOptions.rprivate;
                } else if (std.mem.eql(u8, "unbindable", e.Propagation)) {
                    break :val PropagationOptions.unbindable;
                } else if (std.mem.eql(u8, "runbindable", e.Propagation)) {
                    break :val PropagationOptions.runbindable;
                } else if (std.mem.eql(u8, "", e.Propagation)) {
                    break :val PropagationOptions.none;
                } else {
                    log.err("found unknown mount propagation: {s}\n", .{e.Propagation});
                    return std.json.ParseFromValueError.UnexpectedToken;
                }
            };
            var mount = val: {
                if (std.mem.eql(u8, "devpts", e.Source)) {
                    break :val Mount{
                        .source = e.Source,
                        .destination = e.Destination,
                        .propagation = propagation,
                        .kind = .{ .devpts = .{} },
                        .options = .{ .rw = e.RW },
                    };
                } else if (std.mem.eql(u8, "bind", e.Type)) {
                    break :val Mount{
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
                    break :val Mount{
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
                    log.info("encountered unknown mount option, please report upstream if you think it should be added: {s}\n", .{op});
                }
            }
            mounts[i] = mount;
        }

        var uids = try arena_allocator.alloc(IdMapping(std.posix.uid_t), parsed.HostConfig.IDMappings.UidMap.len);
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
        var gids = try arena_allocator.alloc(IdMapping(std.posix.gid_t), parsed.HostConfig.IDMappings.GidMap.len);
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

        const stop_signal: i32 = val: {
            if (parsed.Config.StopSignal == .string) {
                inline for (comptime std.meta.declarations(std.posix.SIG)) |field| {
                    const value = @field(std.posix.SIG, field.name);
                    const type_info = @typeInfo(@TypeOf(value));
                    if (type_info == .int or type_info == .comptime_int) {
                        if (std.mem.eql(u8, "SIG" ++ field.name, parsed.Config.StopSignal.string)) {
                            break :val value;
                        }
                    }
                } else {
                    return std.json.ParseFromValueError.UnexpectedToken;
                }
            } else {
                break :val @intCast(parsed.Config.StopSignal.integer);
            }
        };

        const umask = try std.fmt.parseInt(std.posix.mode_t, parsed.Config.Umask, 8);

        const created = zeit.instant(.{
            .source = .{
                .rfc3339 = parsed.Created,
            },
        }) catch |err| switch (err) {
            error.InvalidFormat, error.UnhandledFormat, error.InvalidISO8601 => return std.json.ParseFromValueError.InvalidCharacter,
            else => |rest| return rest,
        };

        const state = val: {
            if (std.mem.eql(u8, "created", parsed.State.Status)) {
                break :val State.Created;
            } else if (std.mem.eql(u8, "running", parsed.State.Status)) {
                break :val State.Running;
            } else if (std.mem.eql(u8, "exited", parsed.State.Status)) {
                break :val State.Exited;
            } else {
                break :val State.Unknown;
            }
        };

        return .{ .full = .{
            .arena = arena,
            .id = parsed.Id,
            .name = parsed.Name,
            .mounts = mounts,
            .state = state,
            .created = created,
            .image_id = parsed.Image,
            .idmappings = .{
                .uids = uids,
                .gids = gids,
            },
            .config = .{
                .hostname = parsed.Config.Hostname,
                .cmd = parsed.Config.Cmd,
                .env = env,
                .working_dir = parsed.Config.WorkingDir,
                .labels = labels,
                .annotations = annotations,
                .stop_signal = stop_signal,
                .create_command = parsed.Config.CreateCommand,
                .umask = umask,
            },
        } };
    }

    fn getAllocator(self: Container) std.mem.Allocator {
        switch (self) {
            .minimal => |this| return this.allocator,
            .full => |this| return this.arena.child_allocator,
        }
    }
};

fn getUserName(allocator: std.mem.Allocator) (error{ InvalidFileFormat, StreamTooLong, EndOfStream } || std.fmt.ParseIntError || std.mem.Allocator.Error || std.fs.File.OpenError || std.fs.File.ReadError)![]const u8 {
    const uid = std.os.linux.getuid();
    var file = try std.fs.openFileAbsolute("/etc/passwd", .{});
    defer file.close();
    var buffered_reader = std.io.bufferedReader(file.reader());
    const reader = buffered_reader.reader();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();
    while (true) {
        defer buffer.clearRetainingCapacity();
        try reader.streamUntilDelimiter(buffer.writer(), '\n', null);
        var iter = std.mem.tokenizeScalar(u8, buffer.items, ':');
        const name = iter.next() orelse return error.InvalidFileFormat;
        _ = iter.next();
        const uid_str = iter.next() orelse return error.InvalidFileFormat;
        if (try std.fmt.parseInt(std.posix.uid_t, uid_str, 10) == uid) {
            return try allocator.dupe(u8, name);
        }
    }
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

test "makeFull" {
    var full_example = Container{ .full = .{
        .arena = std.heap.ArenaAllocator.init(std.testing.failing_allocator),
        .id = undefined,
        .name = undefined,
        .state = undefined,
        .created = undefined,
        .image_id = undefined,
        .mounts = undefined,
        .idmappings = undefined,
        .config = undefined,
    } };
    // this should be a NOOP, so test should succeed
    try full_example.makeFull();
}

test "copy" {
    const expect = std.testing.expect;
    const expectEqual = std.testing.expectEqual;
    const expectEqualStrings = std.testing.expectEqualStrings;
    const minimal = Container{
        .minimal = .{
            .allocator = std.testing.allocator,
            .id = "92",
            .name = "name",
            .state = .Created,
            .created = try zeit.instant(.{}),
        },
    };
    var minimal_clone = try minimal.copy(std.testing.allocator);
    defer minimal_clone.deinit();
    try expect(.minimal == minimal_clone);
    try expectEqualStrings(minimal.minimal.id, minimal_clone.minimal.id);
    try expectEqualStrings(minimal.minimal.name, minimal_clone.minimal.name);
    try expectEqual(minimal.minimal.state, minimal_clone.minimal.state);

    var mounts = [_]Mount{
        .{
            .source = "/home",
            .destination = "/home",
            .propagation = .rprivate,
            .options = .{
                .rw = true,
            },
            .kind = .{
                .bind = .{
                    .recursive = true,
                },
            },
        },
        .{
            .source = "/home",
            .destination = "/home",
            .propagation = .rprivate,
            .options = .{
                .rw = true,
            },
            .kind = .{
                .volume = .{
                    .name = "vol",
                },
            },
        },
    };
    var uids = [_]IdMapping(std.posix.uid_t){
        .{
            .start_container = 1,
            .start_host = 1,
            .amount = 1,
        },
    };
    var gids = [_]IdMapping(std.posix.gid_t){
        .{
            .start_container = 2,
            .start_host = 2,
            .amount = 2,
        },
    };
    var cmd = [_][]const u8{
        "/usr/libexec/libnexpod/libnexpodd",
        "--uid",
        "1000",
    };
    var create = [_][]const u8{ "podman", "create", "name" };
    const full = Container{
        .full = .{
            .arena = undefined,
            .id = "92",
            .name = "name",
            .state = .Created,
            .created = try zeit.instant(.{}),
            .image_id = "hi",
            .mounts = &mounts,
            .idmappings = .{
                .uids = &uids,
                .gids = &gids,
            },
            .config = .{
                .hostname = "localhost",
                .cmd = &cmd,
                .env = std.process.EnvMap.init(undefined),
                .working_dir = "/",
                .labels = std.StringHashMapUnmanaged([]const u8){},
                .annotations = std.StringHashMapUnmanaged([]const u8){},
                .stop_signal = std.posix.SIG.ABRT,
                .create_command = &create,
                .umask = 0o22,
            },
        },
    };
    var full_clone = try full.copy(std.testing.allocator);
    defer full_clone.deinit();
    try expect(.full == full_clone);
    try expectEqualStrings(full.full.id, full_clone.full.id);
    try expectEqualStrings(full.full.name, full_clone.full.name);
    try expectEqualStrings(full.full.image_id, full_clone.full.image_id);
    try expectEqual(full.full.state, full_clone.full.state);
    for (full.full.mounts, full_clone.full.mounts) |expected, actual| {
        try expectEqualStrings(expected.source, actual.source);
        try expectEqualStrings(expected.destination, actual.destination);
        try expectEqual(expected.propagation, actual.propagation);
        try expectEqual(expected.options, actual.options);
        switch (expected.kind) {
            .bind => {
                try expect(.bind == actual.kind);
                try expectEqual(expected.kind.bind.recursive, actual.kind.bind.recursive);
            },
            .volume => {
                try expect(.volume == actual.kind);
                try expectEqualStrings(expected.kind.volume.name, actual.kind.volume.name);
            },
            .devpts => {},
        }
    }
    for (full.full.idmappings.uids, full_clone.full.idmappings.uids) |expected, actual| {
        try expectEqual(expected, actual);
    }
    for (full.full.idmappings.gids, full_clone.full.idmappings.gids) |expected, actual| {
        try expectEqual(expected, actual);
    }
    try expectEqualStrings(full.full.config.hostname, full_clone.full.config.hostname);
    try expectEqualStrings(full.full.config.working_dir, full_clone.full.config.working_dir);
    try expectEqual(full.full.config.stop_signal, full_clone.full.config.stop_signal);
    try expectEqual(full.full.config.umask, full_clone.full.config.umask);
    for (full.full.config.cmd, full_clone.full.config.cmd) |expected, actual| {
        try expectEqualStrings(expected, actual);
    }
    for (full.full.config.create_command, full_clone.full.config.create_command) |expected, actual| {
        try expectEqualStrings(expected, actual);
    }
    var env_iter = full.full.config.env.hash_map.keyIterator();
    while (env_iter.next()) |key| {
        try expectEqualStrings(full.full.config.env.get(key.*).?, full_clone.full.config.env.get(key.*).?);
    }
    var labels_iter = full.full.config.labels.keyIterator();
    while (labels_iter.next()) |key| {
        try expectEqualStrings(full.full.config.labels.get(key.*).?, full_clone.full.config.labels.get(key.*).?);
    }
    var annotations_iter = full.full.config.annotations.keyIterator();
    while (annotations_iter.next()) |key| {
        try expectEqualStrings(full.full.config.annotations.get(key.*).?, full_clone.full.config.annotations.get(key.*).?);
    }
}

test "makeFromJson" {
    // this is so far from a toolbx container but with stuff removed because of privacy and size reasons
    // TODO: swap with a libnexpod container
    const id = "1b2001551d16322e8d6b6833548a41dde83b488557deeca44a821ba78fe01656";
    const created = try zeit.instant(.{
        .source = .{
            .rfc3339 = "2024-05-23T21:36:42.621389895+02:00",
        },
    });
    const name = "systemprogrammierung";
    const state = State.Exited;
    const image_id = "a68bd4c6bc4d33757916b2090886d35992933f0fd53590d3c89340446c0dfb16";
    const mount0 = Mount{
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
    const uid0 = IdMapping(std.posix.uid_t){
        .start_container = 0,
        .start_host = 1,
        .amount = 1000,
    };
    const gid0 = IdMapping(std.posix.gid_t){
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
    var parsed = try std.json.parseFromSlice(Container, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const value = parsed.value.full;

    const expectEqual = std.testing.expectEqual;
    const expectEqualStrings = std.testing.expectEqualStrings;

    try expectEqualStrings(id, value.id);
    try expectEqualStrings(name, value.name);
    try expectEqual(state, value.state);
    try expectEqual(created.timestamp, value.created.timestamp);
    try expectEqual(created.timezone.*, value.created.timezone.*);
    try expectEqualStrings(image_id, value.image_id);
    try expectEqualStrings(mount0.source, value.mounts[0].source);
    try expectEqualStrings(mount0.destination, value.mounts[0].destination);
    try expectEqual(mount0.propagation, value.mounts[0].propagation);
    try expectEqual(mount0.kind, value.mounts[0].kind);
    try expectEqual(mount0.kind.bind.recursive, value.mounts[0].kind.bind.recursive);
    try expectEqual(uid0.start_container, value.idmappings.uids[0].start_container);
    try expectEqual(uid0.start_host, value.idmappings.uids[0].start_host);
    try expectEqual(uid0.amount, value.idmappings.uids[0].amount);
    try expectEqual(gid0.start_container, value.idmappings.gids[0].start_container);
    try expectEqual(gid0.start_host, value.idmappings.gids[0].start_host);
    try expectEqual(gid0.amount, value.idmappings.gids[0].amount);
    try expectEqualStrings(hostname, value.config.hostname);
    for (cmd, value.config.cmd) |expected, actual| {
        try expectEqualStrings(expected, actual);
    }
    try expectEqualStrings(env0_value, value.config.env.get(env0_key).?);
    try expectEqualStrings(working_dir, value.config.working_dir);
    try expectEqualStrings(label_value, value.config.labels.get(label_key).?);
    try expectEqualStrings(annotation_value, value.config.annotations.get(annotation_key).?);
    try expectEqual(stop_signal, value.config.stop_signal);
    for (create_command, value.config.create_command) |expected, actual| {
        try expectEqualStrings(expected, actual);
    }
    try expectEqual(umask, value.config.umask);
}

test "full Parse with StopSignal as number" {
    const str =
        \\{"Id":"57212d1cd97283b0abd82ddc4cfd043d0c3669cb38d2b48b9d1f6164f5f58e7a","Created":"2024-10-17T01:58:16.963731673+02:00","Path":"/usr/libexec/libnexpod/libnexpodd","Args":["--uid","1000","--user","dev","--shell","/bin/bash","--home","/home/dev","--group","1000=dev","--group","46=plugdev","--group","4=adm","--group","24=cdrom","--group","27=sudo","--group","30=dip","--group","114=lpadmin","--group","100=users"],"State":{"OciVersion":"1.1.0","Status":"created","Running":false,"Paused":false,"Restarting":false,"OOMKilled":false,"Dead":false,"Pid":0,"ExitCode":0,"Error":"","StartedAt":"0001-01-01T00:00:00Z","FinishedAt":"0001-01-01T00:00:00Z","Health":{"Status":"","FailingStreak":0,"Log":null},"CheckpointedAt":"0001-01-01T00:00:00Z","RestoredAt":"0001-01-01T00:00:00Z"},"Image":"43d8a0ddf9c6769ef5f2a17e791299c06bcb7838a27fc91ce5454236116c90f2","ImageDigest":"sha256:244a97eb5826459d3bacf3245f13ab6131434b43b37e70626006903387115084","ImageName":"localhost/libnexpod-test-archlinux:latest","Rootfs":"","Pod":"","ResolvConfPath":"","HostnamePath":"","HostsPath":"","StaticDir":"/home/dev/.local/share/containers/storage/overlay-containers/57212d1cd97283b0abd82ddc4cfd043d0c3669cb38d2b48b9d1f6164f5f58e7a/userdata","OCIRuntime":"crun","ConmonPidFile":"/run/user/1000/containers/overlay-containers/57212d1cd97283b0abd82ddc4cfd043d0c3669cb38d2b48b9d1f6164f5f58e7a/userdata/conmon.pid","PidFile":"/run/user/1000/containers/overlay-containers/57212d1cd97283b0abd82ddc4cfd043d0c3669cb38d2b48b9d1f6164f5f58e7a/userdata/pidfile","Name":"libnexpod-systemtest-create-name-correct","RestartCount":0,"Driver":"overlay","MountLabel":"","ProcessLabel":"","AppArmorProfile":"","EffectiveCaps":["CAP_AUDIT_CONTROL","CAP_AUDIT_READ","CAP_AUDIT_WRITE","CAP_BLOCK_SUSPEND","CAP_BPF","CAP_CHECKPOINT_RESTORE","CAP_CHOWN","CAP_DAC_OVERRIDE","CAP_DAC_READ_SEARCH","CAP_FOWNER","CAP_FSETID","CAP_IPC_LOCK","CAP_IPC_OWNER","CAP_KILL","CAP_LEASE","CAP_LINUX_IMMUTABLE","CAP_MAC_ADMIN","CAP_MAC_OVERRIDE","CAP_MKNOD","CAP_NET_ADMIN","CAP_NET_BIND_SERVICE","CAP_NET_BROADCAST","CAP_NET_RAW","CAP_PERFMON","CAP_SETFCAP","CAP_SETGID","CAP_SETPCAP","CAP_SETUID","CAP_SYSLOG","CAP_SYS_ADMIN","CAP_SYS_BOOT","CAP_SYS_CHROOT","CAP_SYS_MODULE","CAP_SYS_NICE","CAP_SYS_PACCT","CAP_SYS_PTRACE","CAP_SYS_RAWIO","CAP_SYS_RESOURCE","CAP_SYS_TIME","CAP_SYS_TTY_CONFIG","CAP_WAKE_ALARM"],"BoundingCaps":["CAP_AUDIT_CONTROL","CAP_AUDIT_READ","CAP_AUDIT_WRITE","CAP_BLOCK_SUSPEND","CAP_BPF","CAP_CHECKPOINT_RESTORE","CAP_CHOWN","CAP_DAC_OVERRIDE","CAP_DAC_READ_SEARCH","CAP_FOWNER","CAP_FSETID","CAP_IPC_LOCK","CAP_IPC_OWNER","CAP_KILL","CAP_LEASE","CAP_LINUX_IMMUTABLE","CAP_MAC_ADMIN","CAP_MAC_OVERRIDE","CAP_MKNOD","CAP_NET_ADMIN","CAP_NET_BIND_SERVICE","CAP_NET_BROADCAST","CAP_NET_RAW","CAP_PERFMON","CAP_SETFCAP","CAP_SETGID","CAP_SETPCAP","CAP_SETUID","CAP_SYSLOG","CAP_SYS_ADMIN","CAP_SYS_BOOT","CAP_SYS_CHROOT","CAP_SYS_MODULE","CAP_SYS_NICE","CAP_SYS_PACCT","CAP_SYS_PTRACE","CAP_SYS_RAWIO","CAP_SYS_RESOURCE","CAP_SYS_TIME","CAP_SYS_TTY_CONFIG","CAP_WAKE_ALARM"],"ExecIDs":[],"GraphDriver":{"Name":"overlay","Data":{"LowerDir":"/home/dev/.local/share/containers/storage/overlay/29a680b0297df7dbdc38074769e00916c8938f166d53a6821333cd11ecf235f5/diff:/home/dev/.local/share/containers/storage/overlay/d6c73580dcd0c999232e1082b89adcb51a18fd2f9cb8d145e398ddb88f780cb3/diff:/home/dev/.local/share/containers/storage/overlay/9b035e9cf3608d1ebfeb5a0989e8a0ceafe142db49c4fd651e925e6c8a60b88e/diff:/home/dev/.local/share/containers/storage/overlay/f4c8caf84c436d04cfe6855a421999b93c21655270210959b0a6e70487b6438f/diff:/home/dev/.local/share/containers/storage/overlay/79f3c2e170d06ba98d60a8af91c76890f68b4a45d6ab2e7288cbc74228c2a639/diff","UpperDir":"/home/dev/.local/share/containers/storage/overlay/ebe2074bba9a0c00a608b18be3bbca6f2083b11c47b37925d387a77464083984/diff","WorkDir":"/home/dev/.local/share/containers/storage/overlay/ebe2074bba9a0c00a608b18be3bbca6f2083b11c47b37925d387a77464083984/work"}},"Mounts":[{"Type":"bind","Source":"/etc/hosts","Destination":"/etc/hosts","Driver":"","Mode":"","Options":["rbind"],"RW":false,"Propagation":"rprivate"},{"Type":"bind","Source":"/run/systemd/resolve","Destination":"/run/systemd/resolve","Driver":"","Mode":"","Options":["exec","nosuid","nodev","rbind"],"RW":true,"Propagation":"rslave"},{"Type":"bind","Source":"/etc/host.conf","Destination":"/etc/host.conf","Driver":"","Mode":"","Options":["rbind"],"RW":false,"Propagation":"rprivate"},{"Type":"bind","Source":"/srv","Destination":"/srv","Driver":"","Mode":"","Options":["exec","rbind"],"RW":true,"Propagation":"rslave"},{"Type":"bind","Source":"/sys","Destination":"/sys","Driver":"","Mode":"","Options":["noexec","nosuid","nodev","rbind"],"RW":true,"Propagation":"rslave"},{"Type":"bind","Source":"/mnt","Destination":"/mnt","Driver":"","Mode":"","Options":["exec","rbind"],"RW":true,"Propagation":"rslave"},{"Type":"bind","Source":"/opt","Destination":"/opt","Driver":"","Mode":"","Options":["exec","rbind"],"RW":true,"Propagation":"rslave"},{"Type":"bind","Source":"/run/systemd/users","Destination":"/run/systemd/users","Driver":"","Mode":"","Options":["exec","nosuid","nodev","rbind"],"RW":true,"Propagation":"rslave"},{"Type":"bind","Source":"/media","Destination":"/media","Driver":"","Mode":"","Options":["exec","rbind"],"RW":true,"Propagation":"rslave"},{"Type":"bind","Source":"/run/udev","Destination":"/run/udev","Driver":"","Mode":"","Options":["exec","nosuid","nodev","rbind"],"RW":true,"Propagation":"rslave"},{"Type":"bind","Source":"/run/user/1000","Destination":"/run/user/1000","Driver":"","Mode":"","Options":["exec","nosuid","nodev","rbind"],"RW":true,"Propagation":"rshared"},{"Type":"bind","Source":"/","Destination":"/run/host","Driver":"","Mode":"","Options":["exec","rbind"],"RW":true,"Propagation":"rslave"},{"Type":"bind","Source":"/var/opt","Destination":"/var/opt","Driver":"","Mode":"","Options":["exec","rbind"],"RW":true,"Propagation":"rslave"},{"Type":"bind","Source":"/run/systemd/sessions","Destination":"/run/systemd/sessions","Driver":"","Mode":"","Options":["exec","nosuid","nodev","rbind"],"RW":true,"Propagation":"rslave"},{"Type":"bind","Source":"/var/run/dbus/system_bus_socket","Destination":"/var/run/dbus/system_bus_socket","Driver":"","Mode":"","Options":["bind","noexec","nosuid","nodev"],"RW":true,"Propagation":"rprivate"},{"Type":"bind","Source":"/run/avahi-daemon/socket","Destination":"/run/avahi-daemon/socket","Driver":"","Mode":"","Options":["bind","noexec","nosuid","nodev"],"RW":true,"Propagation":"rprivate"},{"Type":"bind","Source":"/etc/hostname","Destination":"/etc/hostname","Driver":"","Mode":"","Options":["bind"],"RW":false,"Propagation":"rprivate"},{"Type":"bind","Source":"/run/systemd/journal","Destination":"/run/systemd/journal","Driver":"","Mode":"","Options":["exec","nosuid","nodev","rbind"],"RW":true,"Propagation":"rslave"},{"Type":"bind","Source":"/tmp","Destination":"/tmp","Driver":"","Mode":"","Options":["rbind"],"RW":true,"Propagation":"rslave"},{"Type":"bind","Source":"/var/log/journal","Destination":"/var/log/journal","Driver":"","Mode":"","Options":["bind"],"RW":true,"Propagation":"rprivate"},{"Type":"bind","Source":"/home","Destination":"/home","Driver":"","Mode":"","Options":["exec","rbind"],"RW":true,"Propagation":"rslave"},{"Type":"bind","Source":"/home/dev","Destination":"/home/dev","Driver":"","Mode":"","Options":["exec","suid","rbind"],"RW":true,"Propagation":"rshared"},{"Type":"bind","Source":"/etc/resolv.conf","Destination":"/etc/resolv.conf","Driver":"","Mode":"","Options":["bind","noexec","nosuid","nodev"],"RW":false,"Propagation":"rprivate"},{"Type":"bind","Source":"/etc/machine-id","Destination":"/etc/machine-id","Driver":"","Mode":"","Options":["bind","exec"],"RW":false,"Propagation":"rprivate"},{"Type":"bind","Source":"/dev","Destination":"/dev","Driver":"","Mode":"","Options":["dev","exec","nosuid","rbind"],"RW":true,"Propagation":"rslave"},{"Type":"bind","Source":"/var/lib/systemd/coredump","Destination":"/var/lib/systemd/coredump","Driver":"","Mode":"","Options":["bind","exec"],"RW":true,"Propagation":"rprivate"},{"Type":"bind","Source":"/home/dev/libnexpod/.zig-cache/o/49cb0df229fbf0302f504c1fa9693f47/libnexpodd","Destination":"/usr/libexec/libnexpod/libnexpodd","Driver":"","Mode":"","Options":["bind","exec"],"RW":false,"Propagation":"rprivate"},{"Type":"bind","Source":"/run/systemd/system","Destination":"/run/systemd/system","Driver":"","Mode":"","Options":["exec","nosuid","nodev","rbind"],"RW":true,"Propagation":"rslave"}],"Dependencies":[],"NetworkSettings":{"EndpointID":"","Gateway":"","IPAddress":"","IPPrefixLen":0,"IPv6Gateway":"","GlobalIPv6Address":"","GlobalIPv6PrefixLen":0,"MacAddress":"","Bridge":"","SandboxID":"","HairpinMode":false,"LinkLocalIPv6Address":"","LinkLocalIPv6PrefixLen":0,"Ports":{},"SandboxKey":"","Networks":{"host":{"EndpointID":"","Gateway":"","IPAddress":"","IPPrefixLen":0,"IPv6Gateway":"","GlobalIPv6Address":"","GlobalIPv6PrefixLen":0,"MacAddress":"","NetworkID":"host","DriverOpts":null,"IPAMConfig":null,"Links":null}}},"Namespace":"","IsInfra":false,"IsService":false,"KubeExitCodePropagation":"invalid","lockNumber":13,"Config":{"Hostname":"dev-ubuntu","Domainname":"","User":"root:root","AttachStdin":false,"AttachStdout":false,"AttachStderr":false,"Tty":false,"OpenStdin":false,"StdinOnce":false,"Env":["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin","container=podman","LANG=C.UTF-8","HOME=/home/dev","XDG_RUNTIME_DIR=/run/user/1000"],"Cmd":["/usr/libexec/libnexpod/libnexpodd","--uid","1000","--user","dev","--shell","/bin/bash","--home","/home/dev","--group","1000=dev","--group","46=plugdev","--group","4=adm","--group","24=cdrom","--group","27=sudo","--group","30=dip","--group","114=lpadmin","--group","100=users"],"Image":"localhost/libnexpod-test-archlinux:latest","Volumes":null,"WorkingDir":"/","Entrypoint":"","OnBuild":null,"Labels":{"com.github.libnexpod":"libnexpod-systemtest","io.buildah.version":"1.33.7","maintainer":"Kilian Hanich <khanich.opensource@gmx.de>","org.opencontainers.image.authors":"Santiago Torres-Arias <santiago@archlinux.org> (@SantiagoTorres), Christian Rebischke <Chris.Rebischke@archlinux.org> (@shibumi), Justin Kromlinger <hashworks@archlinux.org> (@hashworks)","org.opencontainers.image.created":"2024-10-13T00:07:34+00:00","org.opencontainers.image.description":"Official containerd image of Arch Linux, a simple, lightweight Linux distribution aimed for flexibility.","org.opencontainers.image.documentation":"https://wiki.archlinux.org/title/Docker#Arch_Linux","org.opencontainers.image.licenses":"GPL-3.0-or-later","org.opencontainers.image.revision":"61cb892bfc251e46f73e716ceb3b903ec4e9e725","org.opencontainers.image.source":"https://gitlab.archlinux.org/archlinux/archlinux-docker","org.opencontainers.image.title":"Arch Linux base Image","org.opencontainers.image.url":"https://gitlab.archlinux.org/archlinux/archlinux-docker/-/blob/master/README.md","org.opencontainers.image.version":"20241013.0.269705","summary":"Base Image for Creating Arch Linux libnexpod Containers","usage":"This is meant to be used by the libnexpod library and tools based on it."},"Annotations":{"io.podman.annotations.label":"disable","io.podman.annotations.privileged":"TRUE"},"StopSignal":15,"HealthcheckOnFailureAction":"none","CreateCommand":["podman","create","--cgroupns","host","--dns","none","--ipc","host","--network","host","--no-hosts","--pid","host","--privileged","--security-opt","label=disable","--ulimit","host","--userns","keep-id","--user","root:root","--name","libnexpod-systemtest-create-name-correct","--env","HOME=/home/dev","--env","XDG_RUNTIME_DIR=/run/user/1000","--label","com.github.libnexpod=libnexpod-systemtest","--mount=type=bind,bind-nonrecursive,source=/etc/resolv.conf,destination=/etc/resolv.conf,ro=true","--mount=type=bind,source=/etc/hosts,destination=/etc/hosts,ro=true","--mount=type=bind,source=/etc/host.conf,destination=/etc/host.conf,ro=true","--mount=type=bind,bind-nonrecursive,source=/etc/hostname,destination=/etc/hostname,ro=true","--mount=type=bind,bind-nonrecursive,source=/etc/machine-id,destination=/etc/machine-id,ro=true,exec","--mount=type=bind,source=/,destination=/run/host/,ro=false,exec,rslave","--mount=type=bind,source=/tmp,destination=/tmp,ro=false,rslave","--mount=type=bind,source=/dev,destination=/dev,ro=false,dev,exec,rslave","--mount=type=bind,source=/sys,destination=/sys,ro=false,rslave","--mount=type=bind,bind-nonrecursive,source=/var/log/journal,destination=/var/log/journal,ro=false","--mount=type=bind,bind-nonrecursive,source=/var/lib/systemd/coredump,destination=/var/lib/systemd/coredump,ro=false,exec,rprivate","--mount=type=bind,source=/mnt,destination=/mnt,ro=false,exec,rslave","--mount=type=bind,source=/opt,destination=/opt,ro=false,exec,rslave","--mount=type=bind,source=/var/opt,destination=/var/opt,ro=false,exec,rslave","--mount=type=bind,source=/srv,destination=/srv,ro=false,exec,rslave","--mount=type=bind,source=/home,destination=/home,ro=false,exec,rslave","--mount=type=bind,source=/run/systemd/journal,destination=/run/systemd/journal,ro=false,exec,rslave","--mount=type=bind,source=/run/systemd/resolve,destination=/run/systemd/resolve,ro=false,exec,rslave","--mount=type=bind,source=/run/systemd/sessions,destination=/run/systemd/sessions,ro=false,exec,rslave","--mount=type=bind,source=/run/systemd/system,destination=/run/systemd/system,ro=false,exec,rslave","--mount=type=bind,source=/run/systemd/users,destination=/run/systemd/users,ro=false,exec,rslave","--mount=type=bind,source=/media,destination=/media,ro=false,exec,rslave","--mount=type=bind,source=/run/udev,destination=/run/udev,ro=false,exec,rslave","--mount=type=bind,bind-nonrecursive,source=/var/run/dbus/system_bus_socket,destination=/var/run/dbus/system_bus_socket,ro=false,rprivate","--mount=type=bind,source=/home/dev,destination=/home/dev,ro=false,exec,suid,rshared","--mount=type=bind,source=/run/user/1000,destination=/run/user/1000,ro=false,exec,rshared","--mount=type=bind,bind-nonrecursive,source=/run/avahi-daemon/socket,destination=/run/avahi-daemon/socket,ro=false","--mount=type=bind,bind-nonrecursive,source=/home/dev/libnexpod/.zig-cache/o/49cb0df229fbf0302f504c1fa9693f47/libnexpodd,destination=/usr/libexec/libnexpod/libnexpodd,ro=true,exec","43d8a0ddf9c6769ef5f2a17e791299c06bcb7838a27fc91ce5454236116c90f2","/usr/libexec/libnexpod/libnexpodd","--uid","1000","--user","dev","--shell","/bin/bash","--home","/home/dev","--group","1000=dev","--group","46=plugdev","--group","4=adm","--group","24=cdrom","--group","27=sudo","--group","30=dip","--group","114=lpadmin","--group","100=users"],"Umask":"0022","Timeout":0,"StopTimeout":10,"Passwd":true,"sdNotifyMode":"container"},"HostConfig":{"Binds":["/etc/hosts:/etc/hosts:ro,rprivate,rbind","/run/systemd/resolve:/run/systemd/resolve:exec,rslave,rw,nosuid,nodev,rbind","/etc/host.conf:/etc/host.conf:ro,rprivate,rbind","/srv:/srv:exec,rslave,rw,rbind","/sys:/sys:rslave,rw,noexec,nosuid,nodev,rbind","/mnt:/mnt:exec,rslave,rw,rbind","/opt:/opt:exec,rslave,rw,rbind","/run/systemd/users:/run/systemd/users:exec,rslave,rw,nosuid,nodev,rbind","/media:/media:exec,rslave,rw,rbind","/run/udev:/run/udev:exec,rslave,rw,nosuid,nodev,rbind","/run/user/1000:/run/user/1000:exec,rshared,rw,nosuid,nodev,rbind","/:/run/host:exec,rslave,rw,rbind","/var/opt:/var/opt:exec,rslave,rw,rbind","/run/systemd/sessions:/run/systemd/sessions:exec,rslave,rw,nosuid,nodev,rbind","/var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket:bind,rprivate,rw,noexec,nosuid,nodev","/run/avahi-daemon/socket:/run/avahi-daemon/socket:bind,rw,rprivate,noexec,nosuid,nodev","/etc/hostname:/etc/hostname:bind,ro,rprivate","/run/systemd/journal:/run/systemd/journal:exec,rslave,rw,nosuid,nodev,rbind","/tmp:/tmp:rslave,rw,rbind","/var/log/journal:/var/log/journal:bind,rw,rprivate","/home:/home:exec,rslave,rw,rbind","/home/dev:/home/dev:exec,suid,rshared,rw,rbind","/etc/resolv.conf:/etc/resolv.conf:bind,ro,rprivate,noexec,nosuid,nodev","/etc/machine-id:/etc/machine-id:bind,ro,exec,rprivate","/dev:/dev:dev,exec,rslave,rw,nosuid,rbind","/var/lib/systemd/coredump:/var/lib/systemd/coredump:bind,exec,rprivate,rw","/home/dev/libnexpod/.zig-cache/o/49cb0df229fbf0302f504c1fa9693f47/libnexpodd:/usr/libexec/libnexpod/libnexpodd:bind,ro,exec,rprivate","/run/systemd/system:/run/systemd/system:exec,rslave,rw,nosuid,nodev,rbind"],"CgroupManager":"systemd","CgroupMode":"host","ContainerIDFile":"","LogConfig":{"Type":"journald","Config":null,"Path":"","Tag":"","Size":"0B"},"NetworkMode":"host","PortBindings":{},"RestartPolicy":{"Name":"","MaximumRetryCount":0},"AutoRemove":false,"VolumeDriver":"","VolumesFrom":null,"CapAdd":[],"CapDrop":[],"Dns":[],"DnsOptions":[],"DnsSearch":[],"ExtraHosts":[],"GroupAdd":[],"IpcMode":"host","Cgroup":"","Cgroups":"default","Links":null,"OomScoreAdj":0,"PidMode":"host","Privileged":true,"PublishAllPorts":false,"ReadonlyRootfs":false,"SecurityOpt":["label=disable","unmask=all"],"Tmpfs":{},"UTSMode":"private","UsernsMode":"private","IDMappings":{"UidMap":["0:1:1000","1000:0:1","1001:1001:64536"],"GidMap":["0:1:1000","1000:0:1","1001:1001:64536"]},"ShmSize":65536000,"Runtime":"oci","ConsoleSize":[0,0],"Isolation":"","CpuShares":0,"Memory":0,"NanoCpus":0,"CgroupParent":"user.slice","BlkioWeight":0,"BlkioWeightDevice":null,"BlkioDeviceReadBps":null,"BlkioDeviceWriteBps":null,"BlkioDeviceReadIOps":null,"BlkioDeviceWriteIOps":null,"CpuPeriod":0,"CpuQuota":0,"CpuRealtimePeriod":0,"CpuRealtimeRuntime":0,"CpusetCpus":"","CpusetMems":"","Devices":[],"DiskQuota":0,"KernelMemory":0,"MemoryReservation":0,"MemorySwap":0,"MemorySwappiness":0,"OomKillDisable":false,"PidsLimit":2048,"Ulimits":[],"CpuCount":0,"CpuPercent":0,"IOMaximumIOps":0,"IOMaximumBandwidth":0,"CgroupConf":null}}
    ;
    var parsed = try std.json.parseFromSlice(Container, std.testing.allocator, str, .{});
    defer parsed.deinit();
}
