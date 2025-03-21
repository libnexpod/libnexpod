const std = @import("std");
const utils = @import("utils");
const create = @import("create.zig");
const image = @import("image.zig");
const container = @import("container.zig");
pub const errors = @import("errors.zig");
const log = @import("logging");
const podman = @import("podman-cli.zig");

pub const Image = image.Image;
pub const Name = image.Name;
pub const Container = container.Container;
pub const ContainerConfig = container.ContainerConfig;
pub const IdMapping = container.IdMapping;
pub const Mount = container.Mount;
pub const State = container.State;

/// a management handle to libnexpod related stuff
pub const LibnexpodStorage = struct {
    allocator: std.mem.Allocator,
    key: []const u8,

    pub fn updateContainer(self: LibnexpodStorage, con: *Container) !void {
        const new = try self.getContainer(con.id);
        con.deinit();
        con.* = new;
    }

    /// creates a list of all available libnexpod images on disk in minimal form
    pub fn getImageList(self: LibnexpodStorage) errors.ListErrors![]Image {
        return try podman.listImages(self.allocator);
    }

    test getImageList {
        const nps = try openLibnexpodStorage(std.testing.allocator, "libnexpod-unittest");
        defer nps.deinit();

        const image_list = try nps.getImageList();
        defer {
            for (image_list) |e| {
                e.deinit();
            }
            nps.allocator.free(image_list);
        }
    }

    pub fn getImage(self: LibnexpodStorage, id: []const u8) errors.ListErrors!Image {
        return try podman.getImage(self.allocator, id);
    }

    test getImage {
        const nps = try openLibnexpodStorage(std.testing.allocator, "libnexpod-unittest");
        defer nps.deinit();

        const image_list = try nps.getImageList();
        defer {
            for (image_list) |e| {
                e.deinit();
            }
            nps.allocator.free(image_list);
        }

        const id = image_list[0].id;
        const img = try nps.getImage(if (image_list.len > 0) id else return);
        defer img.deinit();

        try std.testing.expectEqualStrings(id, img.id);
    }

    /// creates a list of all currently existing libnexpod containers with the current key in minimal form
    pub fn getContainerList(self: LibnexpodStorage) errors.ListErrors![]container.Container {
        return try podman.listContainers(self.allocator, self.key);
    }
    test getContainerList {
        const nps = try openLibnexpodStorage(std.testing.allocator, "");
        defer nps.deinit();

        const container_list = try nps.getContainerList();
        defer {
            for (container_list) |e| {
                e.deinit();
            }
            nps.allocator.free(container_list);
        }
    }

    pub fn getContainer(self: LibnexpodStorage, id: []const u8) !Container {
        return try podman.getContainer(self.allocator, self.key, id);
    }

    /// creates a container based on passed in information and gives you back info to the container in full form
    /// you can pass in additional mounts via the `additional_mounts` options if you need to
    /// it uses the current process environment if you don't pass one in manually
    /// it uses the home directory of the current user if you don't specify one manually
    /// it uses the default path /usr/libexec/libnexpod/libnexpodd for libnexpodd_path
    /// all paths must be absolute paths
    /// the ownership of all parameters stays with the caller
    pub fn createContainer(self: LibnexpodStorage, args: struct {
        name: []const u8,
        env: ?std.process.EnvMap = null,
        additional_mounts: []const Mount = &[_]Mount{},
        home: ?[]const u8 = null,
        image: Image,
        libnexpodd_path: ?[]const u8 = null,
    }) !container.Container {
        var tmp_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer tmp_arena.deinit();
        const allocator = tmp_arena.allocator();

        var env = try create.getEnvMap(allocator, args.env);
        const home = try create.getHome(&env, args.home);

        const container_name = val: {
            if (std.mem.eql(u8, "", self.key)) {
                break :val args.name;
            } else {
                break :val try std.mem.concat(allocator, u8, &[_][]const u8{ self.key, "-", args.name });
            }
        };

        const mounts = try create.getMounts(allocator, args.additional_mounts, env, home, args.libnexpodd_path);

        const argv = try create.getEntrypointArgv(allocator, home);

        const id = try podman.createContainer(allocator, .{
            .key = self.key,
            .env = env,
            .name = container_name,
            .image = args.image,
            .entrypoint_argv = argv,
            .mounts = mounts,
        });

        return try self.getContainer(id[0 .. id.len - 1]);
    }

    /// returns necessary resources of ONLY this object storage
    /// you are expected to deinitialize all resources gained from this object (directly or indirectly) before you do this
    pub fn deinit(self: LibnexpodStorage) void {
        self.allocator.free(self.key);
    }
};

/// checks if podman is callable and then initializes a LibnexpodStorage object
/// the ownership of the parameters stays with the caller, but the storage object is not allowed to outlive the allocator
pub fn openLibnexpodStorage(allocator: std.mem.Allocator, key: []const u8) errors.InitStorageErrors!LibnexpodStorage {
    // check if podman exists
    const check_version_argv = [_][]const u8{ "podman", "version" };
    var child = std.process.Child.init(&check_version_argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch |err| switch (err) {
        // Windows-Only
        error.InvalidName,
        error.InvalidHandle,
        error.WaitAbandoned,
        error.WaitTimeOut,
        error.CurrentWorkingDirectoryUnlinked,
        error.InvalidBatchScriptArg,
        error.InvalidWtf8,
        // WASI-Only
        error.InvalidUtf8,
        // not possible from spawn (currently) %TODO: reassess after next Zig update
        error.ProcessAlreadyExec,
        error.ProcessNotFound,
        error.InvalidProcessGroupId,
        => unreachable,
        // we go via env variables, not paths
        error.NoDevice, error.IsDir, error.NotDir, error.BadPathName => unreachable,
        error.OutOfMemory, error.SystemResources, error.AccessDenied, error.InvalidExe, error.FileBusy, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.ResourceLimitReached, error.InvalidUserId, error.FileSystem, error.SymLinkLoop, error.NameTooLong, error.Unexpected => |rest| return rest,
        // Podman not found
        error.PermissionDenied, error.FileNotFound => return errors.PodmanErrors.PodmanNotFound,
    };
    {
        const version = child.stdout.?.readToEndAlloc(allocator, std.math.maxInt(usize)) catch |err| switch (err) {
            error.IsDir,
            error.NotOpenForReading,
            error.SocketNotConnected,
            error.ConnectionResetByPeer,
            error.ConnectionTimedOut,
            error.WouldBlock,
            error.BrokenPipe,
            error.InputOutput,
            error.OperationAborted,
            error.FileTooBig,
            error.LockViolation,
            error.ProcessNotFound,
            => unreachable,
            else => |rest| return rest,
        };
        defer allocator.free(version);
        log.debug("podman version: {s}", .{version});
    }
    const result = child.wait() catch |err| switch (err) {
        // Windows-Only
        error.InvalidName,
        error.InvalidHandle,
        error.WaitAbandoned,
        error.WaitTimeOut,
        error.CurrentWorkingDirectoryUnlinked,
        error.InvalidBatchScriptArg,
        error.InvalidWtf8,
        // WASI-Only
        error.InvalidUtf8,
        // not possible from spawn (currently) %TODO: reassess after next Zig update
        error.ProcessAlreadyExec,
        error.ProcessNotFound,
        error.InvalidProcessGroupId,
        => unreachable,
        // we go via env variables, not paths
        error.OutOfMemory,
        error.NoDevice,
        error.IsDir,
        error.NotDir,
        error.BadPathName,
        => unreachable,
        error.SystemResources,
        error.AccessDenied,
        error.InvalidExe,
        error.FileBusy,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.ResourceLimitReached,
        error.InvalidUserId,
        error.FileSystem,
        error.SymLinkLoop,
        error.NameTooLong,
        error.Unexpected,
        => |rest| return rest,
        // Podman not found
        error.PermissionDenied, error.FileNotFound => return errors.PodmanErrors.PodmanNotFound,
    };
    switch (result) {
        .Exited => |code| {
            switch (code) {
                0 => {},
                else => {
                    log.err("podman failed at getting its version information with exit code {}\n", .{code});
                    return errors.PodmanErrors.PodmanFailed;
                },
            }
        },
        else => |code| {
            log.err("podman failed unexpectedly while getting its version information with code {}\n", .{code});
            return errors.PodmanErrors.PodmanUnexpectedExit;
        },
    }
    const key_copy = try allocator.dupe(u8, key);
    errdefer allocator.free(key_copy);
    return .{
        .allocator = allocator,
        .key = key_copy,
    };
}

test openLibnexpodStorage {
    var nps = try openLibnexpodStorage(std.testing.allocator, "test");
    nps.deinit();
}
