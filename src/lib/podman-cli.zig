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

    return try parseImage(allocator, json);
}

fn parseImage(allocator: std.mem.Allocator, json: []const u8) !Image {
    var tmp_arena = std.heap.ArenaAllocator.init(allocator);
    defer tmp_arena.deinit();
    const tmp_allocator = tmp_arena.allocator();
    const parsed = try std.json.parseFromSliceLeaky(ImageMarshal, tmp_allocator, json, .{ .ignore_unknown_fields = true });

    if (parsed.Config.Labels != .object) return std.json.ParseFromValueError.UnexpectedToken;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const local_allocator = arena.allocator();
    return .{
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

test "makeFromJson big" {
    const id = "a68bd4c6bc4d33757916b2090886d35992933f0fd53590d3c89340446c0dfb16";
    const created_string = "2024-05-23T05:48:16.902538868Z";
    const created = try zeit.instant(.{
        .source = .{
            .rfc3339 = created_string,
        },
    });
    const author = "Fedora Project Contributors <devel@lists.fedoraproject.org>";
    const version = "";
    const names = [_]Name{
        .{
            .repo = "registry.fedoraproject.org",
            .name = "fedora-toolbox",
            .tag = "40",
        },
        .{
            .repo = "localhost",
            .name = "test",
            .tag = "latest",
        },
    };
    const label_keys = [_][]const u8{
        "com.github.containers.toolbox",
        "io.buildah.version",
        "license",
        "name",
        "org.opencontainers.image.license",
        "org.opencontainers.image.name",
        "org.opencontainers.image.url",
        "org.opencontainers.image.vendor",
        "org.opencontainers.image.version",
        "vendor",
        "version",
    };
    const label_values = [_][]const u8{
        "true",
        "1.35.3",
        "MIT",
        "fedora-toolbox",
        "MIT",
        "fedora-toolbox",
        "https://fedoraproject.org/",
        "Fedora Project",
        "40",
        "Fedora Project",
        "40",
    };
    // this key was not the original image, but I added it for testing
    const working_dir = "/";
    const cmd = [_][]const u8{
        "/bin/bash",
    };
    const env_keys = [_][]const u8{
        "container",
    };
    const env_values = [_][]const u8{
        "oci",
    };
    const json =
        \\{
        \\"Id": "a68bd4c6bc4d33757916b2090886d35992933f0fd53590d3c89340446c0dfb16",
        \\"Digest": "sha256:489af52398c4f3ed338b581f62d3b960149f16f64c68da2320e924f77477742f",
        \\"RepoTags": [
        \\"registry.fedoraproject.org/fedora-toolbox:40",
        \\"localhost/test:latest"
        \\],
        \\"RepoDigests": [
        \\"registry.fedoraproject.org/fedora-toolbox@sha256:0895aa9c53ec01ca630541d060c1dd9e43a03f4eece4b491778ff920604f6ed7",
        \\"registry.fedoraproject.org/fedora-toolbox@sha256:489af52398c4f3ed338b581f62d3b960149f16f64c68da2320e924f77477742f"
        \\],
        \\"Parent": "",
        \\"Comment": "",
        \\"Created": "2024-05-23T05:48:16.902538868Z",
        \\"Config": {
        \\"Env": [
        \\"container=oci"
        \\],
        \\"Cmd": [
        \\"/bin/bash"
        \\],
        \\"WorkingDir": "/",
        \\"Labels": {
        \\"com.github.containers.toolbox": "true",
        \\"io.buildah.version": "1.35.3",
        \\"license": "MIT",
        \\"name": "fedora-toolbox",
        \\"org.opencontainers.image.license": "MIT",
        \\"org.opencontainers.image.name": "fedora-toolbox",
        \\"org.opencontainers.image.url": "https://fedoraproject.org/",
        \\"org.opencontainers.image.vendor": "Fedora Project",
        \\"org.opencontainers.image.version": "40",
        \\"vendor": "Fedora Project",
        \\"version": "40"
        \\}
        \\},
        \\"Version": "",
        \\"Author": "Fedora Project Contributors <devel@lists.fedoraproject.org>",
        \\"Architecture": "amd64",
        \\"Os": "linux",
        \\"Size": 2145220341,
        \\"VirtualSize": 2145220341,
        \\"GraphDriver": {
        \\"Name": "overlay",
        \\"Data": {
        \\"UpperDir": "/var/home/kilian/.local/share/containers/storage/overlay/bbfb37c5b121e26d59f53fe96681293fdc361658b8988edfeeca127d4d33f6ac/diff",
        \\"WorkDir": "/var/home/kilian/.local/share/containers/storage/overlay/bbfb37c5b121e26d59f53fe96681293fdc361658b8988edfeeca127d4d33f6ac/work"
        \\}
        \\},
        \\"RootFS": {
        \\"Type": "layers",
        \\"Layers": [
        \\"sha256:bbfb37c5b121e26d59f53fe96681293fdc361658b8988edfeeca127d4d33f6ac"
        \\]
        \\},
        \\"Labels": {
        \\"com.github.containers.toolbox": "true",
        \\"io.buildah.version": "1.35.3",
        \\"license": "MIT",
        \\"name": "fedora-toolbox",
        \\"org.opencontainers.image.license": "MIT",
        \\"org.opencontainers.image.name": "fedora-toolbox",
        \\"org.opencontainers.image.url": "https://fedoraproject.org/",
        \\"org.opencontainers.image.vendor": "Fedora Project",
        \\"org.opencontainers.image.version": "40",
        \\"vendor": "Fedora Project",
        \\"version": "40"
        \\},
        \\"Annotations": {
        \\"org.opencontainers.image.base.digest": "",
        \\"org.opencontainers.image.base.name": ""
        \\},
        \\"ManifestType": "application/vnd.oci.image.manifest.v1+json",
        \\"User": "",
        \\"History": [
        \\{
        \\"created": "2024-05-23T05:48:29.718235695Z",
        \\"created_by": "KIWI 10.0.11",
        \\"author": "Fedora Project Contributors <devel@lists.fedoraproject.org>"
        \\}
        \\],
        \\"NamesHistory": [
        \\"registry.fedoraproject.org/fedora-toolbox:40"
        \\]
        \\}
    ;
    const parsed = try parseImage(std.testing.allocator, json);
    defer parsed.deinit();
    const img = parsed;
    const expect = std.testing.expect;
    const expectEqualStrings = std.testing.expectEqualStrings;
    try expectEqualStrings(id, img.id);
    try std.testing.expectEqual(created, img.created);
    for (names, img.names) |expected, actual| {
        try expectEqualStrings(expected.repo, actual.repo);
        try expectEqualStrings(expected.name, actual.name);
        try expectEqualStrings(expected.tag, actual.tag);
    }
    try expect(img.author != null);
    try expectEqualStrings(author, img.author.?);
    try expect(img.version != null);
    try expectEqualStrings(version, img.version.?);
    for (label_keys, label_values) |key, value| {
        try expect(img.config.labels.contains(key));
        try expectEqualStrings(value, img.config.labels.get(key).?);
    }
    for (env_keys, env_values) |key, value| {
        expect(img.config.env.hash_map.contains(key)) catch |err| {
            std.debug.print("missing key: {s}\n", .{key});
            return err;
        };
        try expectEqualStrings(value, img.config.env.get(key).?);
    }
    for (cmd, img.config.cmd) |expected, actual| {
        try expectEqualStrings(expected, actual);
    }
    try expect(img.config.working_dir != null);
    try expectEqualStrings(working_dir, img.config.working_dir.?);
}

test "makeFromJson wrong input" {
    try std.testing.expectError(error.UnexpectedEndOfInput, parseImage(std.testing.allocator, "{"));
}

test "makeFromJson missing" {
    const id = "\"Id\": \"9292\"";
    const created = "\"Created\": \"2024-08-04T00:07:42Z\"";
    const repo_tags = "\"RepoTags\": [\"localhost/image:latest\"]";
    const env = "\"Env\": [\"PATH=/usr/bin:/usr/sbin:/bin:/sbin\"]";
    const cmd = "\"Cmd\": [\"/bin/bash\"]";
    const labels = "\"Labels\": {\"com.github.libnexpod\":\"true\"}";
    {
        const json =
            \\{
        ++ id ++ "," ++ created ++ "," ++ repo_tags ++
            \\}
        ;
        try std.testing.expectError(error.MissingField, parseImage(std.testing.allocator, json));
    }
    {
        const json =
            \\{
        ++ id ++ "," ++ created ++ "," ++ repo_tags ++ "," ++ "\"config\": {" ++ env ++ "," ++ labels ++
            \\}}
        ;
        try std.testing.expectError(error.MissingField, parseImage(std.testing.allocator, json));
    }
    {
        const json =
            \\{
        ++ id ++ "," ++ created ++ "," ++ repo_tags ++ "," ++ "\"config\": {" ++ env ++ "," ++ cmd ++
            \\}}
        ;
        try std.testing.expectError(error.MissingField, parseImage(std.testing.allocator, json));
    }
    {
        const json =
            \\{
        ++ id ++ "," ++ created ++ "," ++ repo_tags ++ "," ++ "\"config\": {" ++ labels ++ "," ++ cmd ++
            \\}}
        ;
        try std.testing.expectError(error.MissingField, parseImage(std.testing.allocator, json));
    }
    {
        const json =
            \\{
        ++ id ++ "," ++ repo_tags ++ "," ++ "\"config\": {" ++ env ++ "," ++ labels ++ "," ++ cmd ++
            \\}}
        ;
        try std.testing.expectError(error.MissingField, parseImage(std.testing.allocator, json));
    }
    {
        const json =
            \\{
        ++ created ++ "," ++ repo_tags ++ "," ++ "\"config\": {" ++ env ++ "," ++ labels ++ "," ++ cmd ++
            \\}}
        ;
        try std.testing.expectError(error.MissingField, parseImage(std.testing.allocator, json));
    }
    {
        const json =
            \\{
        ++ created ++ "," ++ id ++ "," ++ "\"config\": {" ++ env ++ "," ++ labels ++ "," ++ cmd ++
            \\}}
        ;
        try std.testing.expectError(error.MissingField, parseImage(std.testing.allocator, json));
    }
}
