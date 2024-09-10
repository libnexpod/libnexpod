const builtin = @import("builtin");
const std = @import("std");
const clap = @import("clap");
const log = @import("logging");
const utils = @import("utils");
const get_sudo_group = @import("get_sudo_group.zig").get_sudo_group;
const ensure_user = @import("ensure_user.zig").ensure_user;
const structs = @import("structs.zig");
const Info = structs.Info;
const Group = structs.Group;
const nvidia = @import("nvidia.zig").nvidia;

pub const MainExitCodes = enum(u8) {
    Success = 0,
    NotInContainer = 1,
    SetupError = 2,
    LoopError = 3,
};

pub fn main() u8 {
    if (!utils.isInsideContainer()) {
        log.err("This is supposed to be used inside of a container.\n", .{});
        return @intFromEnum(MainExitCodes.NotInContainer);
    }
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
        .thread_safe = true,
    }){};
    defer if (gpa.deinit() == .leak) {
        log.err("detected memory leak while cleaning up\n", .{});
    };
    const allocator = gpa.allocator();
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        setup(arena.allocator()) catch |err| {
            log.err("encountered critical error during setup: {s}\n", .{@errorName(err)});
            return @intFromEnum(MainExitCodes.SetupError);
        };
    }
    log.info("finished setup", .{});
    loop(allocator) catch |err| {
        log.err("encountered critical error during waiting: {s}\n", .{@errorName(err)});
        return @intFromEnum(MainExitCodes.LoopError);
    };
    return @intFromEnum(MainExitCodes.Success);
}

const LoopErrors = std.fs.File.ReadError || std.posix.TimerFdCreateError || std.posix.TimerFdSetError || error{
    Unexpected,
    EpollCreationFailed,
    ProcessResources,
    InodeMountFail,
    SystemOutdated,
};

fn loop(allocator: std.mem.Allocator) LoopErrors!void {
    // block SIGINT from being processed by a signal handler
    // and setup a signalfd to handle it instead
    var mask: std.os.linux.sigset_t = undefined;
    @memset(&mask, 0);
    std.os.linux.sigaddset(&mask, std.posix.SIG.INT);
    std.os.linux.sigaddset(&mask, std.posix.SIG.KILL);
    std.posix.sigprocmask(std.posix.SIG.BLOCK, &mask, null);
    defer std.posix.sigprocmask(std.posix.SIG.UNBLOCK, &mask, null);
    const signalfd = try std.posix.signalfd(-1, &mask, std.os.linux.SFD.CLOEXEC);
    defer std.posix.close(signalfd);

    // setup a timerfd to with a daily loop
    const timerfd = try std.posix.timerfd_create(std.posix.CLOCK.MONOTONIC, std.os.linux.TFD{ .CLOEXEC = true });
    defer std.posix.close(timerfd);
    const day = std.posix.timespec{
        .tv_sec = 1 * std.time.s_per_day,
        .tv_nsec = 0,
    };
    try std.posix.timerfd_settime(timerfd, std.os.linux.TFD.TIMER{}, &std.os.linux.itimerspec{ .it_interval = day, .it_value = day }, null);

    // setup epoll instance for listening
    const epoll: i32 = @as(i32, @intCast(@as(isize, @bitCast(std.os.linux.epoll_create1(std.os.linux.EPOLL.CLOEXEC)))));
    if (epoll < 0) {
        return error.EpollCreationFailed;
    }
    defer std.posix.close(epoll);
    var event = std.os.linux.epoll_event{
        .events = std.os.linux.EPOLL.IN,
        .data = .{
            .fd = signalfd,
        },
    };
    switch (std.posix.errno(std.os.linux.epoll_ctl(epoll, std.os.linux.EPOLL.CTL_ADD, signalfd, &event))) {
        std.posix.E.SUCCESS => {},
        std.posix.E.NOMEM, std.posix.E.NOSPC => {
            log.err("reached system resource limit while trying to configure epoll\n", .{});
            return error.SystemResources;
        },
        else => unreachable,
    }
    event = std.os.linux.epoll_event{
        .events = std.os.linux.EPOLL.IN,
        .data = .{
            .fd = timerfd,
        },
    };
    switch (std.posix.errno(std.os.linux.epoll_ctl(epoll, std.os.linux.EPOLL.CTL_ADD, timerfd, &event))) {
        std.posix.E.SUCCESS => {},
        std.posix.E.NOMEM, std.posix.E.NOSPC => {
            log.err("reached system resource limit while trying to configure epoll\n", .{});
            return error.SystemResources;
        },
        else => unreachable,
    }
    log.info("finished loop setup", .{});
    while (true) {
        var events: [1]std.os.linux.epoll_event = undefined;
        switch (std.posix.errno(std.os.linux.epoll_wait(epoll, (&events).ptr, 1, -1))) {
            std.posix.E.INTR => {},
            std.posix.E.SUCCESS => {
                const fd: i32 = events[0].data.fd;
                if (fd == signalfd) {
                    var info: std.os.linux.signalfd_siginfo = undefined;
                    if (@sizeOf(@TypeOf(info)) == try std.posix.read(signalfd, std.mem.asBytes(&info))) {
                        return;
                    } else {
                        return std.fs.File.ReadError.InputOutput;
                    }
                } else if (fd == timerfd) {
                    var buffer: [8]u8 = undefined;
                    if (@sizeOf(@TypeOf(buffer)) == try std.posix.read(timerfd, &buffer)) {
                        updatedb(allocator);
                    } else {
                        return std.fs.File.ReadError.InputOutput;
                    }
                } else {
                    log.err("unexpected file descriptor\n", .{});
                    return error.Unexpected;
                }
            },
            else => unreachable,
        }
    }
}

const SetupErrors = std.fmt.AllocPrintError || std.process.Child.RunError || std.process.GetEnvMapError || std.fs.File.OpenError || std.fs.File.ReadError || std.fs.File.WriteError || std.posix.MakeDirError || std.fs.Dir.ChownError || error{
    OutOfMemory,
    InvalidUsage,
    MissingParameter,
    GroupaddFailed,
    GroupaddUnexpectedError,
    NoSudoGroupFound,
    GroupFileProblem,
    UseraddFailed,
    UseraddUnexpectedError,
    UsermodFailed,
    UsermodExpectedError,
    XDGRuntimeDirNotSet,
    NoShellExists,
};

fn setup(allocator: std.mem.Allocator) SetupErrors!void {
    const params = [_]clap.Param(clap.Help){
        .{
            .id = .{
                .desc = "print help",
            },
            .names = .{
                .short = 'h',
                .long = "help",
            },
            .takes_value = .none,
        },
        .{
            .id = .{
                .desc = "uid of the user",
                .val = "u32",
            },
            .names = .{
                .short = null,
                .long = "uid",
            },
            .takes_value = .one,
        },
        .{
            .id = .{
                .desc = "groups of the user; the first one is used as primary; a group is passed in as GID=GROUP_NAME",
                .val = "GROUP",
            },
            .names = .{
                .short = null,
                .long = "group",
            },
            .takes_value = .many,
        },
        .{
            .id = .{
                .desc = "name of the user",
                .val = "string",
            },
            .names = .{
                .short = null,
                .long = "user",
            },
            .takes_value = .one,
        },
        .{
            .id = .{
                .desc = "shell of the user",
                .val = "string",
            },
            .names = .{
                .short = null,
                .long = "shell",
            },
            .takes_value = .one,
        },
        .{
            .id = .{
                .desc = "The path to the home directory of the user inside of the container. This also ensures that it exists if it doesn't.",
                .val = "string",
            },
            .names = .{
                .short = null,
                .long = "home",
            },
            .takes_value = .one,
        },
    };

    const parsers = comptime .{
        .string = clap.parsers.string,
        .u32 = clap.parsers.int(u32, 0),
        .GROUP = Group.parse,
    };
    var diag = clap.Diagnostic{};
    var result = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| switch (err) {
        error.OutOfMemory => {
            log.err("not enough memory to parse CLI arguments", .{});
            return error.OutOfMemory;
        },
        error.DoesntTakeValue, error.MissingValue, error.InvalidArgument => {
            log.err("invalid usage of {s}: {s}", .{ diag.arg, @errorName(err) });
            return error.InvalidUsage;
        },
        error.InvalidCharacter => {
            log.err("invalid usage: received non-number for number argument", .{});
            return error.InvalidUsage;
        },
        else => unreachable,
    };
    defer result.deinit();

    if (result.args.help != 0) {
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{ .markdown_lite = false });
    }
    var info = Info{
        .uid = undefined,
        .group = std.ArrayList(Group).init(allocator),
        .user = undefined,
        .shell = undefined,
        .home = undefined,
    };
    defer info.group.deinit();
    inline for (std.meta.fields(Info)) |field| {
        const element = @field(result.args, field.name);
        if (@typeInfo(@TypeOf(element)) == .Int) {
            @field(info, field.name) = element > 0;
        } else if (comptime std.mem.eql(u8, "group", field.name)) {
            if (result.args.group.len == 0) {
                log.err("you need to specify at least one group\n", .{});
                return error.MissingParameter;
            }
            try info.group.ensureTotalCapacity(result.args.group.len);
            for (result.args.group) |new| {
                for (info.group.items) |old| {
                    if (new.gid == old.gid and std.mem.eql(u8, new.name, old.name)) {
                        break;
                    }
                } else {
                    try info.group.append(new);
                }
            }
        } else {
            if (element) |e| {
                @field(info, field.name) = e;
            } else {
                log.err("missing parameter: {s}\n", .{field.name});
                return error.MissingParameter;
            }
        }
    }

    try ensure_user(allocator, info);
    try host_integration(allocator, info);

    do_updatedb(.{ .allocator = allocator });
}

const ThreadInfo = struct {
    allocator: std.mem.Allocator,
};

// this ignores all possible errors on purpose
fn do_updatedb(info: ThreadInfo) void {
    const res = std.process.Child.run(.{
        .argv = &[_][]const u8{
            "updatedb",
        },
        .allocator = info.allocator,
    }) catch return;
    info.allocator.free(res.stdout);
    info.allocator.free(res.stderr);
}

// this ignores all possible errors on purpose
fn updatedb(allocator: std.mem.Allocator) void {
    const handle = std.Thread.spawn(.{}, do_updatedb, .{ThreadInfo{ .allocator = allocator }}) catch return;
    handle.detach();
}

fn create_nexpod_files(allocator: std.mem.Allocator, uid: std.posix.uid_t, primary_gid: std.posix.gid_t) (std.process.GetEnvMapError || std.posix.MakeDirError || std.fs.File.OpenError || std.fs.Dir.ChownError || error{ OutOfMemory, XDGRuntimeDirNotSet })!struct { std.process.EnvMap, std.fs.Dir } {
    var env = try std.process.getEnvMap(allocator);
    errdefer env.deinit();
    const dir_name = "nexpod";
    const nexpod_dir = val: {
        if (uid == 0) {
            break :val try std.mem.concat(allocator, u8, &[_][]const u8{ "/run/", dir_name });
        } else {
            if (env.get("XDG_RUNTIME_DIR")) |xdg_runtime_dir| {
                break :val try std.mem.concat(allocator, u8, &[_][]const u8{ xdg_runtime_dir, dir_name });
            } else {
                return error.XDGRuntimeDirNotSet;
            }
        }
    };
    defer allocator.free(nexpod_dir);
    if (!utils.fileExists(nexpod_dir)) {
        try std.fs.makeDirAbsolute(nexpod_dir);
    }
    var dir = try std.fs.openDirAbsolute(nexpod_dir, .{ .iterate = true });
    errdefer dir.close();
    try dir.chown(uid, primary_gid);
    (try std.fs.createFileAbsolute("/run/.nexpodenv", .{})).close();
    return .{
        env,
        dir,
    };
}

fn host_integration(allocator: std.mem.Allocator, info: Info) (error{ OutOfMemory, XDGRuntimeDirNotSet } || std.fs.File.OpenError || std.fs.File.WriteError || std.process.GetEnvMapError || std.posix.MakeDirError || std.fs.Dir.ChownError)!void {
    var env: std.process.EnvMap, var runtime_dir: std.fs.Dir = try create_nexpod_files(allocator, info.uid, info.group.items[0].gid);
    defer env.deinit();
    defer runtime_dir.close();
    try nvidia(allocator, runtime_dir);
    // this is basically copied from toolbx, link to commit: https://github.com/containers/toolbox/commit/7542f5fc867b57bf3dc67bbae02cc09ccc0b5df2
    const rpm_dir = "/usr/lib/rpm/macros.d";
    if (utils.fileExists(rpm_dir)) {
        log.info("configuring RPM to ignore bind mounts", .{});
        const file_contents =
            \\# Written by nexpodd\n
            \\# https://github.com/KilianHanich/libnexpod\n
            \\\n
            \\%%_netsharedpath /dev:/media:/mnt:/proc:/sys:/tmp:/var/lib/flatpak:/var/lib/libvirt\n
        ;
        var file = try std.fs.openFileAbsolute(rpm_dir ++ "/macros.nexpod", .{ .mode = .write_only });
        defer file.close();
        try file.writeAll(file_contents);
    }
    const init_stamp = try runtime_dir.createFile("init-time-stamp", .{});
    defer init_stamp.close();
    try init_stamp.writer().print("{}", .{std.time.timestamp()});
}
