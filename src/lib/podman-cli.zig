const std = @import("std");
const zeit = @import("zeit");
const utils = @import("utils");
const log = @import("logging");
const errors = @import("errors.zig");
const image = @import("image.zig");
const Image = image.Image;
const Name = image.Name;

const label = "com.github.libnexpod";

pub fn listImages(allocator: std.mem.Allocator) ![]Image {
    if (utils.isInsideContainer() and !utils.isInsideLibnexpodContainer()) {
        return errors.LibnexpodErrors.InsideNonLibnexpodContainer;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
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
    log.debug("podman-cli.listImages received the following IDs from podman: {s}", .{b: {
        if (log.enabled(.debug)) {
            const dupe = try tmp_allocator.dupe(u8, ids);

            std.mem.replaceScalar(u8, dupe, '\n', ',');
            break :b dupe;
        } else {
            break :b "<placeholder>";
        }
    }});

    const amount = std.mem.count(u8, ids, "\n");
    var result = try std.ArrayListUnmanaged(Image).initCapacity(allocator, amount);
    errdefer {
        for (result.items) |e| {
            e.deinit();
        }
        result.deinit(allocator);
    }

    var iter = std.mem.tokenizeScalar(u8, ids, '\n');
    while (iter.next()) |next| {
        result.appendAssumeCapacity(try getImage(allocator, next));
    }

    return try result.toOwnedSlice(allocator);
}

pub fn getImage(allocator: std.mem.Allocator, id: []const u8) !Image {
    var tmp_arena = std.heap.ArenaAllocator.init(allocator);
    defer tmp_arena.deinit();
    const tmp_allocator = tmp_arena.allocator();

    const json = try call(tmp_allocator, &.{
        "podman",
        "image",
        "inspect",
        "--format",
        "{{ json . }}",
        id,
    });
    log.debug("podman-cli.getImage received the following JSON for the image with the ID {s}: {s}", .{ id, json });

    const parsed = try std.json.parseFromSliceLeaky(ImageMarshal, tmp_allocator, json, .{ .ignore_unknown_fields = true });

    if (parsed.Config.Labels != .object) return std.json.ParseFromValueError.UnexpectedToken;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const local_allocator = arena.allocator();
    return .{
        .full = .{
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
                var names = try local_allocator.alloc(Name, parsed.RepoTags.len);
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
        },
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

fn call(allocator: std.mem.Allocator, argv: []const []const u8) (std.process.Child.RunError || errors.PodmanErrors)![]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = comptime std.math.maxInt(usize),
    }) catch |err| switch (err) {
        error.FileNotFound => {
            log.err("podman not found\n", .{});
            return errors.PodmanErrors.PodmanNotFound;
        },
        else => |rest| return rest,
    };
    errdefer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    switch (result.term) {
        .Exited => |code| {
            if (code == 0) {
                return result.stdout;
            } else {
                var argv_str = std.ArrayList(u8).init(allocator);
                defer argv_str.deinit();
                try argv_str.writer().writeByte('[');
                if (argv.len > 0) {
                    for (argv[0 .. argv.len - 1]) |e| {
                        try argv_str.writer().print("{s}, ", .{e});
                    }
                    try argv_str.writer().print("{s}", .{argv[argv.len - 1]});
                }
                try argv_str.writer().writeByte(']');
                const stderr = if (result.stderr.len > 0 and result.stderr[result.stderr.len - 1] == '\n')
                    result.stderr[0 .. result.stderr.len - 1]
                else
                    result.stderr;
                log.err("Call to podman exited with: {}", .{code});
                log.err("stderr output: {s}", .{stderr});
                log.err("argv was: {s}", .{argv_str.items});
                return errors.PodmanErrors.PodmanFailed;
            }
        },
        else => |code| {
            log.err("Podman exited unexpectedly with {any}\n{s}\n{s}\n", .{ code, result.stdout, result.stderr });
            return errors.PodmanErrors.PodmanUnexpectedExit;
        },
    }
}
test "call" {
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
