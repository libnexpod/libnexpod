const std = @import("std");
const utils = @import("utils");
const list = @import("list.zig");
const create = @import("create.zig");
const image = @import("image.zig");
const container = @import("container.zig");
pub const errors = @import("errors.zig");
const log = @import("logging");

pub const Image = image.Image;
pub const Name = image.Name;
pub const Container = container.Container;
pub const ContainerConfig = container.ContainerConfig;
pub const IdMapping = container.IdMapping;
pub const Mount = container.Mount;

pub const NexpodStorage = struct {
    allocator: std.mem.Allocator,
    key: []const u8,

    pub fn getImages(self: NexpodStorage) errors.ListErrors!std.ArrayList(image.Image) {
        return try list.listImages(self.allocator);
    }

    test getImages {
        const nps = try openNexpodStorage(std.testing.allocator, "");
        defer nps.deinit();

        var image_list = try nps.getImages();
        defer {
            for (image_list.items) |e| {
                e.deinit();
            }
            image_list.deinit();
        }
        for (image_list.items) |*img| {
            try img.makeFull();
        }
    }

    pub fn getContainers(self: NexpodStorage) errors.ListErrors!std.ArrayList(container.Container) {
        return try list.listContainers(self.allocator, self.key);
    }

    test getContainers {
        const nps = try openNexpodStorage(std.testing.allocator, "");
        defer nps.deinit();

        var container_list = try nps.getContainers();
        defer {
            for (container_list.items) |e| {
                e.deinit();
            }
            container_list.deinit();
        }
        for (container_list.items) |*con| {
            try con.makeFull();
        }
    }

    pub fn createContainer(self: NexpodStorage, args: struct {
        name: []const u8,
        env: ?std.process.EnvMap = null,
        additional_mounts: []const Mount = &[_]Mount{},
        home: ?[]const u8 = null,
        image: Image,
    }) errors.CreationErrors!container.Container {
        return try create.createContainer(self.allocator, .{
            .key = self.key,
            .name = args.name,
            .image = args.image,
            .env = args.env,
            .additional_mounts = args.additional_mounts,
            .home_dir = args.home,
        });
    }

    pub fn deinit(self: NexpodStorage) void {
        self.allocator.free(self.key);
    }
};

pub fn openNexpodStorage(allocator: std.mem.Allocator, key: []const u8) errors.InitStorageErrors!NexpodStorage {
    // check if podman exists
    const check_version_argv = [_][]const u8{ "podman", "version" };
    var child = std.process.Child.init(&check_version_argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
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
        => unreachable,
        // we go via env variables, not paths
        error.NoDevice, error.IsDir, error.NotDir, error.BadPathName => unreachable,
        error.OutOfMemory, error.SystemResources, error.AccessDenied, error.InvalidExe, error.FileBusy, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.ResourceLimitReached, error.InvalidUserId, error.FileSystem, error.SymLinkLoop, error.NameTooLong, error.Unexpected => |rest| return rest,
        // Podman not found
        error.PermissionDenied, error.FileNotFound => return errors.PodmanErrors.PodmanNotFound,
    };
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
        => unreachable,
        // we go via env variables, not paths
        error.OutOfMemory, error.NoDevice, error.IsDir, error.NotDir, error.BadPathName => unreachable,
        error.SystemResources, error.AccessDenied, error.InvalidExe, error.FileBusy, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.ResourceLimitReached, error.InvalidUserId, error.FileSystem, error.SymLinkLoop, error.NameTooLong, error.Unexpected => |rest| return rest,
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

test openNexpodStorage {
    var nps = try openNexpodStorage(std.testing.allocator, "test");
    nps.deinit();
}
