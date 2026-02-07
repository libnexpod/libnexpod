const std = @import("std");
const zeit = @import("zeit");
const errors = @import("errors.zig");
const log = @import("logging");
const podman = @import("podman.zig");

/// a combination of the repository, the name and the tag of an image
pub const Name = struct {
    repo: []const u8,
    name: []const u8,
    tag: []const u8,
};

/// The handle to the available information about a libnexpod image.
/// You must call deinit to free the used resources.
pub const Image = struct {
    arena: std.heap.ArenaAllocator,
    id: []const u8,
    names: []const Name,
    created: zeit.Instant,
    version: ?[]const u8 = null,
    author: ?[]const u8 = null,
    config: struct {
        env: std.process.EnvMap,
        cmd: []const []const u8,
        labels: std.hash_map.StringHashMapUnmanaged([]const u8),
        working_dir: ?[]const u8 = null,
    },

    /// This function delete the image from disk but does NOT update the information about and also doesn't free any resources.
    pub fn delete(self: *Image) (std.process.Child.RunError || errors.PodmanErrors)!void {
        const id = self.id;
        const allocator = self.arena.child_allocator;
        try podman.deleteImage(allocator, id);
    }

    /// Creates a copy of this handle with allocator given to this function in whatever information state it currently is.
    pub fn copy(self: Image, allocator: std.mem.Allocator) std.mem.Allocator.Error!Image {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const arena_allocator = arena.allocator();
        const id = try arena_allocator.dupe(u8, self.id);
        var names = try arena_allocator.alloc(Name, self.names.len);
        for (self.names, 0..) |e, i| {
            const repo = try arena_allocator.dupe(u8, e.repo);
            const name = try arena_allocator.dupe(u8, e.name);
            const tag = try arena_allocator.dupe(u8, e.tag);
            names[i] = .{
                .repo = repo,
                .name = name,
                .tag = tag,
            };
        }
        const author = val: {
            if (self.author) |author| {
                break :val try arena_allocator.dupe(u8, author);
            } else {
                break :val null;
            }
        };
        const version = val: {
            if (self.version) |version| {
                break :val try arena_allocator.dupe(u8, version);
            } else {
                break :val null;
            }
        };
        var labels = std.hash_map.StringHashMapUnmanaged([]const u8){};
        var labels_iter = self.config.labels.iterator();
        while (labels_iter.next()) |entry| {
            const key = try arena_allocator.dupe(u8, entry.key_ptr.*);
            const value = try arena_allocator.dupe(u8, entry.value_ptr.*);
            try labels.put(arena_allocator, key, value);
        }
        var env = std.process.EnvMap.init(arena_allocator);
        var env_iter = self.config.env.iterator();
        while (env_iter.next()) |entry| {
            try env.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        var cmd = try arena_allocator.alloc([]const u8, self.config.cmd.len);
        for (self.config.cmd, 0..) |e, i| {
            cmd[i] = try arena_allocator.dupe(u8, e);
        }
        const working_dir = val: {
            if (self.config.working_dir) |working_dir| {
                break :val try arena_allocator.dupe(u8, working_dir);
            } else {
                break :val null;
            }
        };
        return Image{
            .id = id,
            .created = self.created,
            .names = names,
            .version = version,
            .author = author,
            .config = .{
                .env = env,
                .cmd = cmd,
                .working_dir = working_dir,
                .labels = labels,
            },
            .arena = arena,
        };
    }

    /// Frees all resources of this handle.
    pub fn deinit(self: Image) void {
        self.arena.deinit();
    }
};

test "copy" {
    const expectEqualStrings = std.testing.expectEqualStrings;
    var name_array = [_]Name{.{
        .repo = "localhost",
        .name = "test",
        .tag = "latest",
    }};
    var cmd_array = [_][]const u8{
        "/bin/bash",
    };
    const static = Image{
        .arena = undefined,
        .id = "id",
        .created = try zeit.instant(.{}),
        .version = "version",
        .author = "author",
        .names = &name_array,
        .config = .{
            .cmd = &cmd_array,
            .env = std.process.EnvMap.init(undefined),
            .labels = std.StringHashMapUnmanaged([]const u8){},
            .working_dir = "working_dir",
        },
    };
    var copy = try static.copy(std.testing.allocator);
    defer copy.deinit();
    try expectEqualStrings(static.id, copy.id);
    try std.testing.expectEqual(static.created, copy.created);
    try expectEqualStrings(static.version.?, copy.version.?);
    try expectEqualStrings(static.author.?, copy.author.?);
    try expectEqualStrings(static.config.working_dir.?, copy.config.working_dir.?);
    var label_iter = static.config.labels.keyIterator();
    while (label_iter.next()) |key| {
        try expectEqualStrings(static.config.labels.get(key.*).?, copy.config.labels.get(key.*).?);
    }
    var env_iter = static.config.env.hash_map.keyIterator();
    while (env_iter.next()) |key| {
        try expectEqualStrings(static.config.env.get(key.*).?, copy.config.env.get(key.*).?);
    }
    for (copy.config.cmd, static.config.cmd) |actual, expected| {
        try expectEqualStrings(expected, actual);
    }
}
