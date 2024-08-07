const std = @import("std");

pub const NexpodErrors = error{
    InsideNonNexpodContainer,
};

pub const PodmanErrors = error{
    NotFound,
    Failed,
    UnexpectedExit,
};

pub const ImageParseError = std.json.ParseFromValueError || std.json.Scanner.NextError || std.json.Scanner.NextError || std.json.Scanner.AllocError || error{OutOfMemory};
