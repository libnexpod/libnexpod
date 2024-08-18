const std = @import("std");
const utils = @import("utils");
const list = @import("list.zig");
const create = @import("create.zig");
const image = @import("image.zig");
const container = @import("container.zig");
const errors = @import("errors.zig");
const log = @import("logging");

pub const Image = image.Image;
pub const Name = image.Name;
pub const Container = container.Container;
pub const ContainerConfig = container.ContainerConfig;
pub const IdMapping = container.IdMapping;
pub const Mount = container.Mount;

pub fn ObjectIterator(object: type) type {
    return struct {
        objects: std.ArrayList(object),
        index: usize = 0,

        pub fn next(self: *@This()) ?*object {
            if (self.*.index < self.*.objects.items.len) {
                const result = &self.*.objects.items[self.*.index];
                self.*.index += 1;
                return result;
            } else {
                return null;
            }
        }

        pub fn previous(self: *@This()) ?*object {
            if (self.*.index > 0 and self.*.objects.items.len > 0) {
                self.*.index -= 1;
                return &self.*.objects.items[self.*.index];
            } else {
                return null;
            }
        }

        pub fn deinit(self: @This()) void {
            for (self.objects.items) |e| {
                e.deinit();
            }
            self.objects.deinit();
        }
    };
}

pub const NexpodStorage = struct {
    allocator: std.mem.Allocator,
    key: []const u8,

    pub fn getImageIterator(self: NexpodStorage) errors.ListErrors!ObjectIterator(image.Image) {
        return ObjectIterator(image.Image){
            .objects = try list.listImages(self.allocator),
        };
    }

    test getImageIterator {
        const nps = try openNexpodStorage(std.testing.allocator, "");
        defer nps.deinit();

        var image_iter = try nps.getImageIterator();
        defer image_iter.deinit();
        while (image_iter.next()) |img| {
            try img.makeFull();
        }
        while (image_iter.previous()) |_| {}
    }

    pub fn getContainerIterator(self: NexpodStorage) errors.ListErrors!ObjectIterator(container.Container) {
        return ObjectIterator(container.Container){
            .objects = try list.listContainers(self.allocator, self.key),
        };
    }

    test getContainerIterator {
        const nps = try openNexpodStorage(std.testing.allocator, "");
        defer nps.deinit();

        var container_iter = try nps.getContainerIterator();
        defer container_iter.deinit();
        while (container_iter.next()) |con| {
            try con.makeFull();
        }
        while (container_iter.previous()) |_| {}
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

test "ObjectIterator.next" {
    var data_slice = [_]i32{
        -5,
        -4,
        -3,
        -2,
        -1,
        0,
        1,
        2,
        3,
        4,
        5,
    };
    const data = std.ArrayList(i32).fromOwnedSlice(std.testing.allocator, &data_slice);
    var iter_next = ObjectIterator(i32){
        .objects = data,
    };
    try std.testing.expectEqual(null, iter_next.previous());
    var i: usize = 0;
    while (iter_next.next()) |actual| {
        try std.testing.expectEqual(data_slice[i], actual.*);
        i, _ = @addWithOverflow(i, 1);
    }
    try std.testing.expectEqual(null, iter_next.next());
    try std.testing.expectEqual(data_slice.len, iter_next.index);
}

test "ObjectIterator.previous" {
    var data_slice = [_]i32{
        -5,
        -4,
        -3,
        -2,
        -1,
        0,
        1,
        2,
        3,
        4,
        5,
    };
    const data = std.ArrayList(i32).fromOwnedSlice(std.testing.allocator, &data_slice);
    var iter_previous = ObjectIterator(i32){
        .objects = data,
        .index = data_slice.len,
    };
    try std.testing.expectEqual(null, iter_previous.next());
    var i: usize = data_slice.len - 1;
    while (iter_previous.previous()) |actual| {
        try std.testing.expectEqual(data_slice[i], actual.*);
        i, _ = @subWithOverflow(i, 1);
    }
    try std.testing.expectEqual(null, iter_previous.previous());
    try std.testing.expectEqual(0, iter_previous.index);
}
