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
pub const Container = struct {
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

    /// Frees all resources of this handle.
    pub fn deinit(self: Container) void {
        self.arena.deinit();
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
        if (self.state != .Running) {
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

        const argv = try podman.createRunArgs(args.allocator, self.id, args.argv, ttyNeeded, env, args.working_dir, username);
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

    /// Deletes the container from disk. Use `force = true` if you want to delete it even if it currently running.
    /// It does free the resources of this handle.
    pub fn delete(self: *Container, force: bool) (std.process.Child.RunError || errors.PodmanErrors)!void {
        const id = self.id;
        const allocator = self.arena.child_allocator;
        try podman.deleteContainer(allocator, id, force);
    }

    /// Tries to starts the container. The handle information will be updated afterwards.
    pub fn start(self: *Container) errors.UpdateErrors!void {
        const id = self.id;
        const allocator = self.arena.child_allocator;
        // podman sadly doesn't tell us if the container succeeded in starting or immediately died
        // so we instead need to ask for it manually
        try podman.startContainer(allocator, id);
    }

    /// Tries to stop the container. The handle information will be updated afterwards.
    pub fn stop(self: *Container) errors.UpdateErrors!void {
        const id = self.id;
        const allocator = self.arena.child_allocator;
        try podman.stopContainer(allocator, id);
    }

    /// Creates a copy of this handle with allocator given to this function in whatever information state it currently is.
    pub fn copy(self: Container, allocator: std.mem.Allocator) std.mem.Allocator.Error!Container {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();
        const id = try arena_allocator.dupe(u8, self.id);
        const name = try arena_allocator.dupe(u8, self.name);
        const image_id = try arena_allocator.dupe(u8, self.image_id);
        var mounts = try arena_allocator.alloc(Mount, self.mounts.len);
        for (self.mounts, 0..) |e, i| {
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
        var uids = try arena_allocator.alloc(IdMapping(std.posix.uid_t), self.idmappings.uids.len);
        for (self.idmappings.uids, 0..) |e, i| {
            uids[i] = e;
        }
        var gids = try arena_allocator.alloc(IdMapping(std.posix.gid_t), self.idmappings.gids.len);
        for (self.idmappings.gids, 0..) |e, i| {
            gids[i] = e;
        }
        const hostname = try arena_allocator.dupe(u8, self.config.hostname);
        var cmd = try arena_allocator.alloc([]const u8, self.config.cmd.len);
        for (self.config.cmd, 0..) |e, i| {
            cmd[i] = try arena_allocator.dupe(u8, e);
        }
        const working_dir = try arena_allocator.dupe(u8, self.config.working_dir);
        var env = std.process.EnvMap.init(arena_allocator);
        var env_iter = self.config.env.iterator();
        while (env_iter.next()) |entry| {
            try env.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var labels = std.StringHashMapUnmanaged([]const u8){};
        var labels_iter = self.config.labels.iterator();
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
        var create_command = try arena_allocator.alloc([]const u8, self.config.create_command.len);
        for (self.config.create_command, 0..) |e, i| {
            create_command[i] = try arena_allocator.dupe(u8, e);
        }
        return .{
            .arena = arena,
            .id = id,
            .name = name,
            .state = self.state,
            .created = self.created,
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
                .stop_signal = self.config.stop_signal,
                .create_command = create_command,
                .umask = self.config.umask,
            },
        };
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

test "copy" {
    const expect = std.testing.expect;
    const expectEqual = std.testing.expectEqual;
    const expectEqualStrings = std.testing.expectEqualStrings;
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
    const static = Container{
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
    };
    var clone = try static.copy(std.testing.allocator);
    defer clone.deinit();
    try expectEqualStrings(static.id, clone.id);
    try expectEqualStrings(static.name, clone.name);
    try expectEqualStrings(static.image_id, clone.image_id);
    try expectEqual(static.state, clone.state);
    for (static.mounts, clone.mounts) |expected, actual| {
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
    for (static.idmappings.uids, clone.idmappings.uids) |expected, actual| {
        try expectEqual(expected, actual);
    }
    for (static.idmappings.gids, clone.idmappings.gids) |expected, actual| {
        try expectEqual(expected, actual);
    }
    try expectEqualStrings(static.config.hostname, clone.config.hostname);
    try expectEqualStrings(static.config.working_dir, clone.config.working_dir);
    try expectEqual(static.config.stop_signal, clone.config.stop_signal);
    try expectEqual(static.config.umask, clone.config.umask);
    for (static.config.cmd, clone.config.cmd) |expected, actual| {
        try expectEqualStrings(expected, actual);
    }
    for (static.config.create_command, clone.config.create_command) |expected, actual| {
        try expectEqualStrings(expected, actual);
    }
    var env_iter = static.config.env.hash_map.keyIterator();
    while (env_iter.next()) |key| {
        try expectEqualStrings(static.config.env.get(key.*).?, clone.config.env.get(key.*).?);
    }
    var labels_iter = static.config.labels.keyIterator();
    while (labels_iter.next()) |key| {
        try expectEqualStrings(static.config.labels.get(key.*).?, clone.config.labels.get(key.*).?);
    }
    var annotations_iter = static.config.annotations.keyIterator();
    while (annotations_iter.next()) |key| {
        try expectEqualStrings(static.config.annotations.get(key.*).?, clone.config.annotations.get(key.*).?);
    }
}
