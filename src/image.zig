const Self = @This();
const std = @import("std");
const errors = @import("errors.zig");
const log = @import("logging.zig");

allocator: std.mem.Allocator,
id: []const u8,
created: []const u8,
repo_tags: []const RepoTag,
version: ?[]const u8,
author: ?[]const u8,
config: struct {
    env: std.process.EnvMap,
    cmd: []const []const u8,
    labels: std.hash_map.StringHashMap([]const u8),
    working_dir: ?[]const u8,
    fn deinit(self: *@This()) void {
        const parent: *Self = @fieldParentPtr("config", self);
        const allocator = parent.allocator;
        self.env.deinit();
        for (self.cmd) |arg| {
            allocator.free(arg);
        }
        allocator.free(self.cmd);
        var iter = self.labels.iterator();
        while (iter.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.labels.deinit();
        if (self.working_dir) |working_dir| {
            allocator.free(working_dir);
        }
    }
},

const RepoTag = struct {
    repo: []const u8,
    name: []const u8,
    tag: []const u8,
};

pub fn makeFromJson(allocator: std.mem.Allocator, json: []const u8) errors.ImageParseError!Self {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    if (parsed.value != std.json.Value.object) {
        log.err("Podman gave unexpected json output\n", .{});
        return errors.ImageParseError.UnexpectedToken;
    }
    const tmp_empty_u8_array: []const u8 = try allocator.alloc(u8, 0);
    defer allocator.free(tmp_empty_u8_array);
    const tmp_empty_array_of_u8_arrays: []const []const u8 = try allocator.alloc([]const u8, 0);
    defer allocator.free(tmp_empty_array_of_u8_arrays);
    const tmp_empty_array_of_repo_tags: []const RepoTag = try allocator.alloc(RepoTag, 0);
    defer allocator.free(tmp_empty_array_of_repo_tags);
    var self: Self = .{
        .allocator = allocator,
        .id = tmp_empty_u8_array,
        .created = tmp_empty_u8_array,
        .repo_tags = tmp_empty_array_of_repo_tags,
        .version = null,
        .author = null,
        .config = .{
            .env = std.process.EnvMap.init(allocator),
            .cmd = tmp_empty_array_of_u8_arrays,
            .labels = std.hash_map.StringHashMap([]const u8).init(allocator),
            .working_dir = null,
        },
    };
    errdefer {
        const deinit_fields = [_][]const u8{
            "env",
            "labels",
        };
        inline for (@typeInfo(Self).Struct.fields) |field| {
            const element = @field(self, field.name);
            switch (@typeInfo(field.type)) {
                .Optional => if (@field(self, field.name)) |e| {
                    self.allocator.free(e);
                },
                .Pointer => if (comptime std.mem.eql(u8, field.name, "repo_tags")) {
                    if (element.ptr != tmp_empty_array_of_repo_tags.ptr) {
                        for (element) |e| {
                            self.allocator.free(e.repo);
                            self.allocator.free(e.name);
                            self.allocator.free(e.tag);
                        }
                        self.allocator.free(element);
                    }
                } else if (@intFromPtr(element.ptr) != @intFromPtr(tmp_empty_array_of_u8_arrays.ptr) and @intFromPtr(element.ptr) != @intFromPtr(tmp_empty_u8_array.ptr)) {
                    if (@TypeOf(element) == @TypeOf(tmp_empty_array_of_u8_arrays)) {
                        for (element) |e| {
                            self.allocator.free(e);
                        }
                    }
                    self.allocator.free(element);
                },
                .Struct => if (comptime std.mem.eql(u8, field.name, "allocator")) {
                    continue;
                } else if (comptime std.mem.eql(u8, field.name, "config")) {
                    inline for (@typeInfo(@TypeOf(self.config)).Struct.fields) |sub_field| {
                        var sub_element = @field(self.config, sub_field.name);
                        switch (@typeInfo(sub_field.type)) {
                            .Optional => if (@field(self.config, sub_field.name)) |e| {
                                self.allocator.free(e);
                            },
                            .Pointer => if (@intFromPtr(sub_element.ptr) != @intFromPtr(tmp_empty_u8_array.ptr) and @intFromPtr(sub_element.ptr) != @intFromPtr(tmp_empty_array_of_u8_arrays.ptr)) {
                                if (@TypeOf(sub_element) == @TypeOf(tmp_empty_array_of_u8_arrays)) {
                                    for (sub_element) |e| {
                                        self.allocator.free(e);
                                    }
                                }
                                self.allocator.free(sub_element);
                            },
                            .Struct => inline for (deinit_fields) |e| {
                                if (comptime std.mem.eql(u8, sub_field.name, e)) {
                                    sub_element.deinit();
                                    break;
                                }
                            },
                            else => unreachable,
                        }
                    }
                } else {
                    unreachable;
                },
                else => unreachable,
            }
        }
    }
    inline for (@typeInfo(Self).Struct.fields) |field| {
        if (comptime std.mem.eql(u8, field.name, "allocator")) {
            continue;
        } else if (comptime std.mem.eql(u8, field.name, "config")) {
            if (parsed.value.object.get("Config")) |value| {
                if (value != std.json.Value.object) {
                    return errors.ImageParseError.UnexpectedToken;
                }
                if (value.object.get("Env")) |val| {
                    if (val != std.json.Value.array) {
                        return errors.ImageParseError.UnexpectedToken;
                    }
                    for (val.array.items) |element| {
                        if (element != std.json.Value.string) {
                            return errors.ImageParseError.UnexpectedToken;
                        }
                        if (std.mem.indexOf(u8, element.string, "=")) |index| {
                            try self.config.env.put(element.string[0..index], element.string[index + 1 .. element.string.len]);
                        } else {
                            return errors.ImageParseError.UnexpectedToken;
                        }
                    }
                }
                if (value.object.get("Labels")) |val| {
                    if (val != std.json.Value.object) {
                        return errors.ImageParseError.UnexpectedToken;
                    }
                    var iter = val.object.iterator();
                    while (iter.next()) |entry| {
                        if (entry.value_ptr.* != std.json.Value.string) {
                            return errors.ImageParseError.UnexpectedToken;
                        }
                        const k = try allocator.dupe(u8, entry.key_ptr.*);
                        errdefer allocator.free(k);
                        const e = try allocator.dupe(u8, entry.value_ptr.*.string);
                        errdefer allocator.free(e);
                        try self.config.labels.put(k, e);
                    }
                } else {
                    return errors.ImageParseError.MissingField;
                }
                if (value.object.get("Cmd")) |val| {
                    if (val != std.json.Value.array) {
                        return errors.ImageParseError.UnexpectedToken;
                    }
                    var cmd = try allocator.alloc([]const u8, val.array.items.len);
                    @memset(cmd, tmp_empty_u8_array);
                    errdefer {
                        for (cmd) |e| {
                            if (e.ptr != tmp_empty_u8_array.ptr) {
                                allocator.free(e);
                            }
                        }
                        allocator.free(cmd);
                    }
                    for (val.array.items, 0..) |e, i| {
                        if (e != std.json.Value.string) {
                            return errors.ImageParseError.UnexpectedToken;
                        }
                        cmd[i] = try allocator.dupe(u8, e.string);
                    }
                    self.config.cmd = cmd;
                } else {
                    return errors.ImageParseError.MissingField;
                }
                if (value.object.get("WorkingDir")) |val| {
                    if (val != std.json.Value.string) {
                        return errors.ImageParseError.UnexpectedToken;
                    }
                    self.config.working_dir = try allocator.dupe(u8, val.string);
                }
            } else {
                return errors.ImageParseError.MissingField;
            }
        } else if (comptime std.mem.eql(u8, field.name, "repo_tags")) {
            if (parsed.value.object.get("RepoTags")) |value| {
                if (value != std.json.Value.array) {
                    return errors.ImageParseError.UnexpectedToken;
                }
                var tags = try allocator.alloc(RepoTag, value.array.items.len);
                @memset(tags, RepoTag{ .repo = tmp_empty_u8_array, .name = tmp_empty_u8_array, .tag = tmp_empty_u8_array });
                errdefer {
                    for (tags) |e| {
                        if (e.name.ptr != tmp_empty_u8_array.ptr) {
                            allocator.free(e.name);
                        }
                        if (e.repo.ptr != tmp_empty_u8_array.ptr) {
                            allocator.free(e.repo);
                        }
                        if (e.tag.ptr != tmp_empty_u8_array.ptr) {
                            allocator.free(e.tag);
                        }
                    }
                    allocator.free(tags);
                }
                for (value.array.items, 0..) |e, i| {
                    if (e != std.json.Value.string) {
                        return errors.ImageParseError.UnexpectedToken;
                    }
                    const tag_sep = std.mem.lastIndexOf(u8, e.string, ":");
                    if (tag_sep == null) {
                        return errors.ImageParseError.UnexpectedToken;
                    }
                    const name_sep = std.mem.lastIndexOf(u8, e.string, "/");
                    if (name_sep == null) {
                        return errors.ImageParseError.UnexpectedToken;
                    }
                    tags[i].tag = try allocator.dupe(u8, e.string[tag_sep.? + 1 ..]);
                    tags[i].name = try allocator.dupe(u8, e.string[name_sep.? + 1 .. tag_sep.?]);
                    tags[i].repo = try allocator.dupe(u8, e.string[0..name_sep.?]);
                }
                self.repo_tags = tags;
            } else {
                self.repo_tags = try allocator.dupe(RepoTag, tmp_empty_array_of_repo_tags);
            }
        } else {
            var capitalized: [field.name.len]u8 = undefined;
            @memcpy(&capitalized, field.name);
            if ('a' <= capitalized[0] and capitalized[0] <= 'z') {
                capitalized[0] -= ('a' - 'A');
            }
            if (parsed.value.object.get(&capitalized)) |value| {
                if (value != std.json.Value.string) {
                    return errors.ImageParseError.UnexpectedToken;
                }
                @field(self, field.name) = try allocator.dupe(u8, value.string);
            } else if (@typeInfo(field.type) != .Optional) {
                log.err("missing field name: {s}", .{field.name});
                return errors.ImageParseError.MissingField;
            }
        }
    }
    return self;
}

test "makeFromJson small" {
    const id = "9292";
    const created = "2024-08-04T00:07:42Z";
    const repo_tag = RepoTag{ .repo = "localhost", .name = "test", .tag = "latest" };
    const env_key = "PATH";
    const env_value = "/usr/bin:/usr/sbin:/bin:/sbin";
    const cmd = "/bin/bash";
    const label_key = "com.github.kilianhanich.nexpod";
    const label_value = "true";
    const json =
        \\{"Id": "
    ++ id ++
        \\", "Created": "
    ++ created ++
        \\", "RepoTags": ["
    ++ repo_tag.repo ++ "/" ++ repo_tag.name ++ ":" ++ repo_tag.tag ++
        \\"], "Config": {"Env": [ "
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
    var img = try makeFromJson(std.testing.allocator, json);
    defer img.deinit();
    const expectEqualSlices = std.testing.expectEqualSlices;
    try expectEqualSlices(u8, id, img.id);
    try expectEqualSlices(u8, created, img.created);
    try std.testing.expect(img.repo_tags.len == 1);
    try expectEqualSlices(u8, repo_tag.repo, img.repo_tags[0].repo);
    try expectEqualSlices(u8, repo_tag.name, img.repo_tags[0].name);
    try expectEqualSlices(u8, repo_tag.tag, img.repo_tags[0].tag);
    try std.testing.expect(img.config.env.hash_map.contains(env_key));
    try expectEqualSlices(u8, env_value, img.config.env.get(env_key).?);
    try std.testing.expect(img.config.cmd.len == 1);
    try expectEqualSlices(u8, cmd, img.config.cmd[0]);
    try std.testing.expect(img.config.labels.contains(label_key));
    try expectEqualSlices(u8, label_value, img.config.labels.get(label_key).?);

    // null checks
    try std.testing.expect(img.author == null);
    try std.testing.expect(img.version == null);
    try std.testing.expect(img.author == null);
}

test "makeFromJson big" {
    const id = "a68bd4c6bc4d33757916b2090886d35992933f0fd53590d3c89340446c0dfb16";
    const created = "2024-05-23T05:48:16.902538868Z";
    const author = "Fedora Project Contributors <devel@lists.fedoraproject.org>";
    const version = "";
    const repo_tags = [_]RepoTag{
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
    var img = try makeFromJson(std.testing.allocator, json);
    defer img.deinit();
    const expect = std.testing.expect;
    const expectEqualSlices = std.testing.expectEqualSlices;
    try expectEqualSlices(u8, id, img.id);
    try expectEqualSlices(u8, created, img.created);
    for (repo_tags, img.repo_tags) |expected, actual| {
        try expectEqualSlices(u8, expected.repo, actual.repo);
        try expectEqualSlices(u8, expected.name, actual.name);
        try expectEqualSlices(u8, expected.tag, actual.tag);
    }
    try expect(img.author != null);
    try expectEqualSlices(u8, author, img.author.?);
    try expect(img.version != null);
    try expectEqualSlices(u8, version, img.version.?);
    for (label_keys, label_values) |key, value| {
        try expect(img.config.labels.contains(key));
        try expectEqualSlices(u8, value, img.config.labels.get(key).?);
    }
    for (env_keys, env_values) |key, value| {
        try expect(img.config.env.hash_map.contains(key));
        try expectEqualSlices(u8, value, img.config.env.get(key).?);
    }
    for (cmd, img.config.cmd) |expected, actual| {
        try expectEqualSlices(u8, expected, actual);
    }
    try expect(img.config.working_dir != null);
    try expectEqualSlices(u8, working_dir, img.config.working_dir.?);
}

test "makeFromJson wrong input" {
    try std.testing.expectError(errors.ImageParseError.UnexpectedEndOfInput, makeFromJson(std.testing.allocator, "{"));
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
        try std.testing.expectError(errors.ImageParseError.MissingField, makeFromJson(std.testing.allocator, json));
    }
    {
        const json =
            \\{
        ++ id ++ "," ++ created ++ "," ++ repo_tags ++ "," ++ "\"config\": {" ++ env ++ "," ++ labels ++
            \\}}
        ;
        try std.testing.expectError(errors.ImageParseError.MissingField, makeFromJson(std.testing.allocator, json));
    }
    {
        const json =
            \\{
        ++ id ++ "," ++ created ++ "," ++ repo_tags ++ "," ++ "\"config\": {" ++ env ++ "," ++ cmd ++
            \\}}
        ;
        try std.testing.expectError(errors.ImageParseError.MissingField, makeFromJson(std.testing.allocator, json));
    }
    {
        const json =
            \\{
        ++ id ++ "," ++ created ++ "," ++ repo_tags ++ "," ++ "\"config\": {" ++ labels ++ "," ++ cmd ++
            \\}}
        ;
        try std.testing.expectError(errors.ImageParseError.MissingField, makeFromJson(std.testing.allocator, json));
    }
    {
        const json =
            \\{
        ++ id ++ "," ++ repo_tags ++ "," ++ "\"config\": {" ++ env ++ "," ++ labels ++ "," ++ cmd ++
            \\}}
        ;
        try std.testing.expectError(errors.ImageParseError.MissingField, makeFromJson(std.testing.allocator, json));
    }
    {
        const json =
            \\{
        ++ created ++ "," ++ repo_tags ++ "," ++ "\"config\": {" ++ env ++ "," ++ labels ++ "," ++ cmd ++
            \\}}
        ;
        try std.testing.expectError(errors.ImageParseError.MissingField, makeFromJson(std.testing.allocator, json));
    }
    {
        const json =
            \\{
        ++ created ++ "," ++ id ++ "," ++ "\"config\": {" ++ env ++ "," ++ labels ++ "," ++ cmd ++
            \\}}
        ;
        try std.testing.expectError(errors.ImageParseError.MissingField, makeFromJson(std.testing.allocator, json));
    }
}

pub fn deinit(self: *Self) void {
    inline for (@typeInfo(Self).Struct.fields) |field| {
        const element = @field(self, field.name);
        switch (@typeInfo(field.type)) {
            .Optional => if (element) |e| {
                self.allocator.free(e);
            },
            .Pointer => |p| if (@typeInfo(p.child) == .Pointer) {
                for (element) |e| {
                    self.allocator.free(e);
                }
                self.allocator.free(element);
            } else if (comptime std.mem.eql(u8, field.name, "repo_tags")) {
                for (element) |e| {
                    self.allocator.free(e.repo);
                    self.allocator.free(e.name);
                    self.allocator.free(e.tag);
                }
                self.allocator.free(element);
            } else {
                self.allocator.free(element);
            },
            .Struct => if (comptime std.mem.eql(u8, field.name, "config")) {
                self.config.deinit();
            } else if (comptime std.mem.eql(u8, field.name, "allocator")) {
                continue;
            } else {
                unreachable;
            },
            else => unreachable,
        }
    }
}
