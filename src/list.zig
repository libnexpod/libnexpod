const std = @import("std");
const utils = @import("utils.zig");
const errors = @import("errors.zig");
const podman = @import("podman.zig");
const Image = @import("image.zig");

pub fn listImages(allocator: std.mem.Allocator) (errors.ImageParseError || errors.NexpodErrors || errors.PodmanErrors || std.process.Child.RunError)!std.ArrayList(Image) {
    if (utils.isInsideContainer() and !utils.isInsideNexpodContainer()) {
        return errors.NexpodErrors.InsideNonNexpodContainer;
    }
    const imagesJson = try podman.getImages(allocator);
    defer {
        for (imagesJson.items) |e| {
            allocator.free(e);
        }
        imagesJson.deinit();
    }

    var images = std.ArrayList(Image).init(allocator);
    errdefer {
        for (images.items) |*e| {
            e.deinit();
        }
        images.deinit();
    }

    for (imagesJson.items) |json| {
        var img = try Image.makeFromJson(allocator, json);
        errdefer img.deinit();
        try images.append(img);
    }
    return images;
}
