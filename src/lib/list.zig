const std = @import("std");
const utils = @import("utils");
const log = @import("logging");
const zeit = @import("zeit");
const errors = @import("errors.zig");
const podman = @import("podman.zig");
const images = @import("image.zig");
const containers = @import("container.zig");

pub fn listImages(allocator: std.mem.Allocator) errors.ListErrors!std.ArrayList(images.Image) {
    if (utils.isInsideContainer() and !utils.isInsideNexpodContainer()) {
        return errors.NexpodErrors.InsideNonNexpodContainer;
    }
    const json = try podman.getImageListJSON(allocator);
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice([]ImageMarshall, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var image_list = try std.ArrayList(images.Image).initCapacity(allocator, parsed.value.len);
    errdefer {
        for (image_list.items) |*e| {
            e.deinit();
        }
        image_list.deinit();
    }

    for (parsed.value) |element| {
        var names = try std.ArrayList(images.Name).initCapacity(allocator, element.Names.len);
        errdefer {
            for (names.items) |e| {
                allocator.free(e.repo);
                allocator.free(e.name);
                allocator.free(e.tag);
            }
            names.deinit();
        }
        for (element.Names) |e| {
            const repo_name_divider = std.mem.lastIndexOf(u8, e, "/") orelse return std.json.Scanner.NextError.SyntaxError;
            const name_tag_divider = std.mem.lastIndexOf(u8, e, ":") orelse return std.json.Scanner.NextError.SyntaxError;
            const repo = try allocator.dupe(u8, e[0..repo_name_divider]);
            errdefer allocator.free(repo);
            const name = try allocator.dupe(u8, e[repo_name_divider + 1 .. name_tag_divider]);
            errdefer allocator.free(name);
            const tag = try allocator.dupe(u8, e[name_tag_divider + 1 .. e.len]);
            errdefer allocator.free(tag);
            try names.append(.{
                .repo = repo,
                .name = name,
                .tag = tag,
            });
        }
        const id = try allocator.dupe(u8, element.Id);
        errdefer allocator.free(id);
        const names_slice = try names.toOwnedSlice();
        errdefer {
            for (names_slice) |e| {
                allocator.free(e.repo);
                allocator.free(e.name);
                allocator.free(e.tag);
            }
            allocator.free(names_slice);
        }
        try image_list.append(images.Image{
            .minimal = .{
                .allocator = allocator,
                .id = id,
                .names = names_slice,
                .created = zeit.instant(.{
                    .source = .{
                        .rfc3339 = element.CreatedAt,
                    },
                }) catch |err| switch (err) {
                    error.InvalidFormat, error.UnhandledFormat, error.InvalidISO8601 => return std.json.ParseFromValueError.InvalidCharacter,
                    else => |rest| return rest,
                },
            },
        });
    }
    return image_list;
}

pub fn listContainers(allocator: std.mem.Allocator, key: []const u8) errors.ListErrors!std.ArrayList(containers.Container) {
    if (utils.isInsideContainer() and !utils.isInsideNexpodContainer()) {
        return errors.NexpodErrors.InsideNonNexpodContainer;
    }
    const json = try podman.getContainerListJSON(allocator, key);
    defer allocator.free(json);

    var parsed = try std.json.parseFromSlice([]ContainerMarshall, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var container_list = try std.ArrayList(containers.Container).initCapacity(allocator, parsed.value.len);
    errdefer {
        for (container_list.items) |*e| {
            e.deinit();
        }
        container_list.deinit();
    }

    for (parsed.value) |element| {
        if (element.Names.len < 1) {
            log.err("Listed container with ID {s} doesn't have a name", .{element.Id});
            return errors.PodmanErrors.PodmanInvalidOutput;
        }

        const name = try allocator.dupe(u8, element.Names[0]);
        errdefer allocator.free(name);

        const id = try allocator.dupe(u8, element.Id);
        errdefer allocator.free(id);

        const state: containers.State = val: {
            if (std.mem.eql(u8, "exited", element.State)) {
                break :val .Exited;
            } else if (std.mem.eql(u8, "running", element.State)) {
                break :val .Running;
            } else if (std.mem.eql(u8, "created", element.State)) {
                break :val .Created;
            } else {
                break :val .Unknown;
            }
        };

        const created = zeit.instant(.{
            .source = .{
                .unix_timestamp = element.Created,
            },
        }) catch unreachable;

        try container_list.append(containers.Container{
            .minimal = .{
                .allocator = allocator,
                .id = id,
                .name = name,
                .state = state,
                .created = created,
            },
        });
    }
    return container_list;
}

const ImageMarshall = struct {
    Names: []const []const u8,
    Id: []const u8,
    CreatedAt: []const u8,
};

test listImages {
    var image_list = listImages(std.testing.allocator) catch |err| switch (err) {
        error.InsideNonNexpodContainer => {
            std.debug.print("inside non-nexpod container, ignoring test\n", .{});
            return;
        },
        else => |rest| return rest,
    };
    defer {
        for (image_list.items) |*e| {
            e.deinit();
        }
        image_list.deinit();
    }
}

const ContainerMarshall = struct {
    Names: []const []const u8,
    Id: []const u8,
    State: []const u8,
    Created: i64,
};

test listContainers {
    var container_list = listContainers(std.testing.allocator, "") catch |err| switch (err) {
        error.InsideNonNexpodContainer => {
            std.debug.print("inside non-nexpod container, ignoring test\n", .{});
            return;
        },
        else => |rest| return rest,
    };
    defer {
        for (container_list.items) |*e| {
            e.deinit();
        }
        container_list.deinit();
    }
}
