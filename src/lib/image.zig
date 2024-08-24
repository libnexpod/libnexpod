const std = @import("std");
const zeit = @import("zeit");
const errors = @import("errors.zig");
const log = @import("logging");
const podman = @import("podman.zig");

pub const Name = struct {
    repo: []const u8,
    name: []const u8,
    tag: []const u8,
};

pub const Image = union(enum) {
    minimal: struct {
        allocator: std.mem.Allocator,
        id: []const u8,
        names: []const Name,
        created: zeit.Instant,
    },
    full: struct {
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
    },

    pub fn delete(self: *Image) (std.process.Child.RunError || errors.PodmanErrors)!void {
        const id = self.getId();
        const allocator = self.getAllocator();
        try podman.deleteImage(allocator, id);
    }

    pub fn getId(self: Image) []const u8 {
        switch (self) {
            .minimal => |this| return this.id,
            .full => |this| return this.id,
        }
    }

    pub fn makeFull(self: *Image) errors.UpdateErrors!void {
        switch (self.*) {
            .full => {},
            .minimal => |this| {
                const allocator = this.allocator;
                const id = this.id;
                const names = this.names;
                const json = try podman.getImageJSON(allocator, id);
                defer allocator.free(json);
                var parsed = try std.json.parseFromSlice(Image, allocator, json, .{});
                defer parsed.deinit();
                const new = try copy(parsed.value, allocator);
                self.* = new;
                allocator.free(id);
                for (names) |e| {
                    allocator.free(e.repo);
                    allocator.free(e.name);
                    allocator.free(e.tag);
                }
                allocator.free(names);
            },
        }
    }

    pub fn copy(self: Image, allocator: std.mem.Allocator) std.mem.Allocator.Error!Image {
        switch (self) {
            .minimal => |this| {
                const id = try allocator.dupe(u8, this.id);
                errdefer allocator.free(id);
                var names = try std.ArrayList(Name).initCapacity(allocator, this.names.len);
                errdefer {
                    for (names.items) |e| {
                        allocator.free(e.repo);
                        allocator.free(e.name);
                        allocator.free(e.tag);
                    }
                    names.deinit();
                }
                for (this.names) |e| {
                    const repo = try allocator.dupe(u8, e.repo);
                    errdefer allocator.free(repo);
                    const name = try allocator.dupe(u8, e.name);
                    errdefer allocator.free(name);
                    const tag = try allocator.dupe(u8, e.tag);
                    errdefer allocator.free(tag);
                    try names.append(.{
                        .repo = repo,
                        .name = name,
                        .tag = tag,
                    });
                }
                const names_list = try names.toOwnedSlice();
                errdefer {
                    for (names_list) |e| {
                        allocator.free(e.repo);
                        allocator.free(e.name);
                        allocator.free(e.tag);
                    }
                    allocator.free(names_list);
                }
                return Image{
                    .minimal = .{
                        .allocator = allocator,
                        .id = id,
                        .names = names_list,
                        .created = this.created,
                    },
                };
            },
            .full => |this| {
                var arena = std.heap.ArenaAllocator.init(allocator);
                errdefer arena.deinit();
                const arena_allocator = arena.allocator();
                const id = try arena_allocator.dupe(u8, this.id);
                var names = try arena_allocator.alloc(Name, this.names.len);
                for (this.names, 0..) |e, i| {
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
                    if (this.author) |author| {
                        break :val try arena_allocator.dupe(u8, author);
                    } else {
                        break :val null;
                    }
                };
                const version = val: {
                    if (this.version) |version| {
                        break :val try arena_allocator.dupe(u8, version);
                    } else {
                        break :val null;
                    }
                };
                var labels = std.hash_map.StringHashMapUnmanaged([]const u8){};
                var labels_iter = this.config.labels.iterator();
                while (labels_iter.next()) |entry| {
                    const key = try arena_allocator.dupe(u8, entry.key_ptr.*);
                    const value = try arena_allocator.dupe(u8, entry.value_ptr.*);
                    try labels.put(arena_allocator, key, value);
                }
                var env = std.process.EnvMap.init(arena_allocator);
                var env_iter = this.config.env.iterator();
                while (env_iter.next()) |entry| {
                    try env.put(entry.key_ptr.*, entry.value_ptr.*);
                }
                var cmd = try arena_allocator.alloc([]const u8, this.config.cmd.len);
                for (this.config.cmd, 0..) |e, i| {
                    cmd[i] = try arena_allocator.dupe(u8, e);
                }
                const working_dir = val: {
                    if (this.config.working_dir) |working_dir| {
                        break :val try arena_allocator.dupe(u8, working_dir);
                    } else {
                        break :val null;
                    }
                };
                return Image{
                    .full = .{
                        .arena = arena,
                        .id = id,
                        .created = this.created,
                        .names = names,
                        .version = version,
                        .author = author,
                        .config = .{
                            .env = env,
                            .cmd = cmd,
                            .working_dir = working_dir,
                            .labels = labels,
                        },
                    },
                };
            },
        }
    }

    pub fn deinit(self: Image) void {
        switch (self) {
            .full => |this| {
                this.arena.deinit();
            },
            .minimal => |this| {
                this.allocator.free(this.id);
                for (this.names) |e| {
                    this.allocator.free(e.repo);
                    this.allocator.free(e.name);
                    this.allocator.free(e.tag);
                }
                this.allocator.free(this.names);
            },
        }
    }

    // this function is intended to be used by the std.json parsing framework and is leaky
    pub fn jsonParse(allocator: std.mem.Allocator, scanner_or_reader: anytype, options: std.json.ParseOptions) (std.json.ParseError(@TypeOf(scanner_or_reader.*)) || std.mem.Allocator.Error)!Image {
        const parsed = try std.json.parseFromTokenSourceLeaky(ImageMarshall, allocator, scanner_or_reader, .{
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

        const id = parsed.Id;
        const created = parsed.Created;
        var names = try arena_allocator.alloc(Name, parsed.RepoTags.len);
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
                .repo = repo,
                .name = name,
                .tag = tag,
            };
        }
        const version = parsed.Version;
        const author = parsed.Author;

        var cmd = try arena_allocator.alloc([]const u8, parsed.Config.Cmd.len);
        for (parsed.Config.Cmd, 0..) |c, i| {
            cmd[i] = c;
        }

        const working_dir = parsed.Config.WorkingDir;

        return Image{
            .full = .{
                .arena = arena,
                .id = id,
                .created = zeit.instant(.{
                    .source = .{
                        .rfc3339 = created,
                    },
                }) catch |err| switch (err) {
                    error.InvalidFormat, error.UnhandledFormat, error.InvalidISO8601 => return std.json.ParseFromValueError.InvalidCharacter,
                    else => |rest| return rest,
                },
                .names = names,
                .version = version,
                .author = author,
                .config = .{
                    .env = env,
                    .cmd = cmd,
                    .working_dir = working_dir,
                    .labels = labels,
                },
            },
        };
    }

    fn getAllocator(self: Image) std.mem.Allocator {
        switch (self) {
            .minimal => |this| return this.allocator,
            .full => |this| return this.arena.child_allocator,
        }
    }
};

const ImageMarshall = struct {
    Id: []const u8,
    Created: []const u8,
    RepoTags: []const []const u8,
    Version: ?[]const u8 = null,
    Author: ?[]const u8 = null,
    Config: struct {
        Env: []const []const u8,
        Cmd: []const []const u8,
        Labels: std.json.Value,
        WorkingDir: ?[]const u8 = null,
    },
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
    const full_static = Image{
        .full = .{
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
        },
    };
    var full = try full_static.copy(std.testing.allocator);
    defer full.deinit();
    try std.testing.expect(full == .full);
    try expectEqualStrings(full_static.full.id, full.full.id);
    try std.testing.expectEqual(full_static.full.created, full.full.created);
    try expectEqualStrings(full_static.full.version.?, full.full.version.?);
    try expectEqualStrings(full_static.full.author.?, full.full.author.?);
    try expectEqualStrings(full_static.full.config.working_dir.?, full.full.config.working_dir.?);
    var label_iter = full_static.full.config.labels.keyIterator();
    while (label_iter.next()) |key| {
        try expectEqualStrings(full_static.full.config.labels.get(key.*).?, full.full.config.labels.get(key.*).?);
    }
    var env_iter = full_static.full.config.env.hash_map.keyIterator();
    while (env_iter.next()) |key| {
        try expectEqualStrings(full_static.full.config.env.get(key.*).?, full.full.config.env.get(key.*).?);
    }
    for (full.full.config.cmd, full_static.full.config.cmd) |actual, expected| {
        try expectEqualStrings(expected, actual);
    }

    const name_list = [_]Name{
        .{
            .repo = "localhost",
            .name = "test",
            .tag = "latest",
        },
    };
    const minimal_static = Image{
        .minimal = .{
            .allocator = undefined,
            .id = "9292",
            .names = &name_list,
            .created = try zeit.instant(.{}),
        },
    };
    var minimal = try minimal_static.copy(std.testing.allocator);
    defer minimal.deinit();
    try std.testing.expect(minimal == .minimal);
    try expectEqualStrings(minimal_static.minimal.id, minimal.minimal.id);
    for (name_list, minimal.minimal.names) |expected, actual| {
        try expectEqualStrings(expected.repo, actual.repo);
        try expectEqualStrings(expected.name, actual.name);
        try expectEqualStrings(expected.tag, actual.tag);
    }
    try std.testing.expectEqual(minimal_static.minimal.created, minimal.minimal.created);
}

test "makeFull" {
    var full_example = Image{ .full = .{
        .arena = std.heap.ArenaAllocator.init(std.testing.failing_allocator),
        .id = undefined,
        .names = undefined,
        .created = undefined,
        .version = undefined,
        .author = undefined,
        .config = undefined,
    } };
    // this should be a NOOP, so test should succeed
    try full_example.makeFull();
}

test "makeFromJson small" {
    const id = "9292";
    const created_string = "2024-08-04T00:07:42Z";
    const created = try zeit.instant(.{
        .source = .{
            .rfc3339 = created_string,
        },
    });
    const repo_tag = Name{ .repo = "localhost", .name = "test", .tag = "latest" };
    const env_key = "PATH";
    const env_value = "/usr/bin:/usr/sbin:/bin:/sbin";
    const cmd = "/bin/bash";
    const label_key = "com.github.kilianhanich.nexpod";
    const label_value = "true";
    const json =
        \\{"Id": "
    ++ id ++
        \\", "Created": "
    ++ created_string ++
        \\", "RepoTags": ["
    ++ repo_tag.repo ++ "/" ++ repo_tag.name ++ ":" ++ repo_tag.tag ++
        \\"],
        ++
        \\"Config": {"Env": ["
    ++ env_key ++
        \\=
    ++ env_value ++
        \\"],
        ++
        \\"Cmd": ["
    ++ cmd ++
        \\"],
        ++
        \\"Labels": {"
    ++ label_key ++
        \\": "
    ++ label_value ++
        \\"}
        ++
        \\}}
    ;
    const parsed = try std.json.parseFromSlice(Image, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const img = parsed.value.full;
    const expectEqualStrings = std.testing.expectEqualStrings;
    try expectEqualStrings(id, img.id);
    try std.testing.expectEqual(created, img.created);
    try std.testing.expect(img.names.len == 1);
    try expectEqualStrings(repo_tag.repo, img.names[0].repo);
    try expectEqualStrings(repo_tag.name, img.names[0].name);
    try expectEqualStrings(repo_tag.tag, img.names[0].tag);
    try std.testing.expect(img.config.env.hash_map.contains(env_key));
    try expectEqualStrings(env_value, img.config.env.get(env_key).?);
    try std.testing.expect(img.config.cmd.len == 1);
    try expectEqualStrings(cmd, img.config.cmd[0]);
    try std.testing.expect(img.config.labels.contains(label_key));
    try expectEqualStrings(label_value, img.config.labels.get(label_key).?);

    // null checks
    try std.testing.expect(img.author == null);
    try std.testing.expect(img.version == null);
    try std.testing.expect(img.author == null);
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
    const parsed = try std.json.parseFromSlice(Image, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const img = parsed.value.full;
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
    try std.testing.expectError(error.UnexpectedEndOfInput, std.json.parseFromSlice(Image, std.testing.allocator, "{", .{}));
}

test "makeFromJson missing" {
    const id = "\"Id\": \"9292\"";
    const created = "\"Created\": \"2024-08-04T00:07:42Z\"";
    const repo_tags = "\"RepoTags\": [\"localhost/image:latest\"]";
    const env = "\"Env\": [\"PATH=/usr/bin:/usr/sbin:/bin:/sbin\"]";
    const cmd = "\"Cmd\": [\"/bin/bash\"]";
    const labels = "\"Labels\": {\"com.github.kilianhanich.nexpod\":\"true\"}";
    {
        const json =
            \\{
        ++ id ++ "," ++ created ++ "," ++ repo_tags ++
            \\}
        ;
        try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Image, std.testing.allocator, json, .{}));
    }
    {
        const json =
            \\{
        ++ id ++ "," ++ created ++ "," ++ repo_tags ++ "," ++ "\"config\": {" ++ env ++ "," ++ labels ++
            \\}}
        ;
        try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Image, std.testing.allocator, json, .{}));
    }
    {
        const json =
            \\{
        ++ id ++ "," ++ created ++ "," ++ repo_tags ++ "," ++ "\"config\": {" ++ env ++ "," ++ cmd ++
            \\}}
        ;
        try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Image, std.testing.allocator, json, .{}));
    }
    {
        const json =
            \\{
        ++ id ++ "," ++ created ++ "," ++ repo_tags ++ "," ++ "\"config\": {" ++ labels ++ "," ++ cmd ++
            \\}}
        ;
        try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Image, std.testing.allocator, json, .{}));
    }
    {
        const json =
            \\{
        ++ id ++ "," ++ repo_tags ++ "," ++ "\"config\": {" ++ env ++ "," ++ labels ++ "," ++ cmd ++
            \\}}
        ;
        try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Image, std.testing.allocator, json, .{}));
    }
    {
        const json =
            \\{
        ++ created ++ "," ++ repo_tags ++ "," ++ "\"config\": {" ++ env ++ "," ++ labels ++ "," ++ cmd ++
            \\}}
        ;
        try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Image, std.testing.allocator, json, .{}));
    }
    {
        const json =
            \\{
        ++ created ++ "," ++ id ++ "," ++ "\"config\": {" ++ env ++ "," ++ labels ++ "," ++ cmd ++
            \\}}
        ;
        try std.testing.expectError(error.MissingField, std.json.parseFromSlice(Image, std.testing.allocator, json, .{}));
    }
}
