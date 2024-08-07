const std = @import("std");

pub const NexpodErrors = error{
    InsideNonNexpodContainer,
};

pub const PodmanErrors = error{
    NotFound,
    Failed,
    UnexpectedExit,
};
