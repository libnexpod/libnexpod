const std = @import("std");

/// all errors emitted related to errors of this library
pub const LibnexpodErrors = error{
    InsideNonLibnexpodContainer,
};

/// all errors emitted related to errors of podman
pub const PodmanErrors = error{
    PodmanNotFound,
    PodmanFailed,
    PodmanUnexpectedExit,
    PodmanInvalidOutput,
};

/// all errors which can happen while creating a container
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

/// all errors which can happen while listing out containers of images
pub const ListErrors = LibnexpodErrors || PodmanErrors || std.json.ParseFromValueError || std.json.Scanner.AllocError || std.json.Scanner.NextError || std.process.Child.RunError;

/// all images which can happen when update the info of a container
pub const UpdateErrors = std.json.ParseError(std.json.Scanner) || std.process.Child.RunError || PodmanErrors || std.mem.Allocator.Error;

/// all errors which can happen when trying to run a command inside of a container
pub const RunCommandErrors = std.mem.Allocator.Error || std.process.Child.SpawnError || std.fs.File.OpenError || std.fs.File.ReadError || std.fmt.ParseIntError || error{
    ContainerNotRunning,
    InvalidFileFormat,
    StreamTooLong,
    EndOfStream,
};

/// all errors which can happen when opening LibnexpodStorage
pub const InitStorageErrors = PodmanErrors || error{ OutOfMemory, SystemResources, AccessDenied, InvalidExe, FileBusy, ProcessFdQuotaExceeded, SystemFdQuotaExceeded, ResourceLimitReached, InvalidUserId, FileSystem, SymLinkLoop, NameTooLong, Unexpected };
