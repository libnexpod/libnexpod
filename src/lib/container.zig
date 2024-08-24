const std = @import("std");
const builtin = @import("builtin");
const log = @import("logging");
const zeit = @import("zeit");
const podman = @import("podman.zig");
const errors = @import("errors.zig");

pub const State = enum {
    Exited,
    Running,
    Created,
    Unknown,
};

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

pub fn IdMapping(kind: type) type {
    return struct {
        start_container: kind,
        start_host: kind,
        amount: usize,
    };
}

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

    pub fn update(self: *Container) errors.UpdateErrors!void {
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

    pub fn delete(self: *Container, force: bool) (std.process.Child.RunError || errors.PodmanErrors)!void {
        const id = self.getId();
        const allocator = self.getAllocator();
        try podman.deleteContainer(allocator, id, force);
    }

    // the container will be in the full information state afterwards if podman itself doesn't error out or memory runs out
    pub fn start(self: *Container) errors.UpdateErrors!void {
        const id = self.getId();
        const allocator = self.getAllocator();
        // podman sadly doesn't tell us if the container succeeded in starting or immediately died
        // so we instead need to ask for it manually
        try podman.startContainer(allocator, id);
        try self.update();
    }

    // the container will be in the full information state afterwards if podman itself doesn't error out or memory runs out
    pub fn stop(self: *Container) errors.UpdateErrors!void {
        const id = self.getId();
        const allocator = self.getAllocator();
        try podman.stopContainer(allocator, id);
        try self.update();
    }

    pub fn getId(self: Container) []const u8 {
        switch (self) {
            .minimal => |this| return this.id,
            .full => |this| return this.id,
        }
    }

    pub fn makeFull(self: *Container) errors.UpdateErrors!void {
        switch (self.*) {
            .full => {},
            .minimal => try self.update(),
        }
    }

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

    // this function is intended to be used by the std.json parsing framework and is leaky
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
                } else if (std.mem.eql(u8, "nosuid", op) or std.mem.eql(u8, "noexec", op) or std.mem.eql(u8, "nodev", op)) {
                    continue;
                } else if (std.mem.eql(u8, "rbind", op)) {
                    mount.kind.bind.recursive = true;
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
            inline for (comptime std.meta.declarations(std.posix.SIG)) |field| {
                const value = @field(std.posix.SIG, field.name);
                const type_info = @typeInfo(@TypeOf(value));
                if (type_info == .Int or type_info == .ComptimeInt) {
                    if (std.mem.eql(u8, "SIG" ++ field.name, parsed.Config.StopSignal)) {
                        break :val value;
                    }
                }
            } else {
                return std.json.ParseFromValueError.UnexpectedToken;
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
        StopSignal: []const u8,
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
        "/usr/libexec/nexpod/nexpodd",
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
    // TODO: swap with a nexpod container
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
