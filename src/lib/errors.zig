const std = @import("std");

pub const NexpodErrors = error{
    InsideNonNexpodContainer,
};

pub const PodmanErrors = error{
    NotFound,
    Failed,
    UnexpectedExit,
    InvalidOutput,
};

pub const CreationErrors = error{
    NeededEnvironmentVariableNotFound,
};

pub const ListErrors = NexpodErrors || PodmanErrors || std.json.ParseFromValueError || std.json.Scanner.AllocError || std.json.Scanner.NextError || std.process.Child.RunError;

pub const InitStorageErrors = PodmanErrors || error{ OutOfMemory, SystemResources, AccessDenied, InvalidExe, FileBusy, ProcessFdQuotaExceeded, SystemFdQuotaExceeded, ResourceLimitReached, InvalidUserId, FileSystem, SymLinkLoop, NameTooLong, Unexpected };
