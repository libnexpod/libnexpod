const std = @import("std");

pub const NexpodErrors = error{
    InsideNonNexpodContainer,
};

pub const PodmanErrors = error{
    PodmanNotFound,
    PodmanFailed,
    PodmanUnexpectedExit,
    PodmanInvalidOutput,
};

pub const CreationErrors = std.mem.Allocator.Error || std.fmt.ParseIntError || std.fs.File.OpenError || std.fs.File.ReadError || std.posix.ReadLinkError || std.process.Child.RunError || std.json.ParseError(std.json.Scanner) || PodmanErrors || error{
    NoHomeFound,
    InvalidValueInEnvironment,
    NeededEnvironmentVariableNotFound,
    InvalidFileFormat,
    UsernameNotFound,
    NoRuntimeDirFound,
    StreamTooLong,
    EndOfStream,
    PrimaryGroupnameNotFound,
};

pub const ListErrors = NexpodErrors || PodmanErrors || std.json.ParseFromValueError || std.json.Scanner.AllocError || std.json.Scanner.NextError || std.process.Child.RunError;

pub const UpdateErrors = std.json.ParseError(std.json.Scanner) || std.process.Child.RunError || PodmanErrors || std.mem.Allocator.Error;

pub const RunCommandErrors = std.mem.Allocator.Error || std.process.Child.SpawnError || std.fs.File.OpenError || std.fs.File.ReadError || std.fmt.ParseIntError || error{
    ContainerNotRunning,
    InvalidFileFormat,
    StreamTooLong,
    EndOfStream,
};

pub const InitStorageErrors = PodmanErrors || error{ OutOfMemory, SystemResources, AccessDenied, InvalidExe, FileBusy, ProcessFdQuotaExceeded, SystemFdQuotaExceeded, ResourceLimitReached, InvalidUserId, FileSystem, SymLinkLoop, NameTooLong, Unexpected };
