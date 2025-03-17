const std = @import("std");
const utils = @import("utils");
const log = @import("logging");
const zeit = @import("zeit");
const errors = @import("errors.zig");
const podman = @import("podman.zig");
const images = @import("image.zig");
const containers = @import("container.zig");

pub fn listContainers(allocator: std.mem.Allocator, key: []const u8) errors.ListErrors!std.ArrayList(containers.Container) {
    if (utils.isInsideContainer() and !utils.isInsideLibnexpodContainer()) {
        return errors.LibnexpodErrors.InsideNonLibnexpodContainer;
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

const ContainerMarshall = struct {
    Names: []const []const u8,
    Id: []const u8,
    State: []const u8,
    Created: i64,
};

test listContainers {
    var container_list = listContainers(std.testing.allocator, "") catch |err| switch (err) {
        error.InsideNonLibnexpodContainer => {
            std.debug.print("inside non-libnexpod container, ignoring test\n", .{});
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
