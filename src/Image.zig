const std = @import("std");
const RGBAImage = @import("image").RGBAImage;
const Rectangle = @import("image").Rectangle;
const zgpu = @import("zgpu");
const ResourceManager = @import("ResourceManager.zig");
const Geom = @import("Geom.zig");

/// Represents a 2D image in the Zonk engine
/// Wraps the RGBAImage type from zpix
pub const Image = @This();

/// The underlying RGBAImage
rgba_image: RGBAImage,
allocator: std.mem.Allocator,
/// Sub-image bounds when this is a sub-image
sub_bounds: ?Rectangle = null,

/// Options for drawing images
pub const DrawImageOptions = struct {
    geom: Geom,
};

/// Create a new image with the given dimensions
pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !*Image {
    const image = try allocator.create(Image);

    const bounds = Rectangle{
        .min = .{ .x = 0, .y = 0 },
        .max = .{ .x = @intCast(width), .y = @intCast(height) },
    };

    image.* = .{
        .rgba_image = try RGBAImage.init(allocator, bounds),
        .allocator = allocator,
    };

    return image;
}

/// Load an image from a file path
pub fn fromFile(allocator: std.mem.Allocator, gfx: *zgpu.GraphicsContext, path: []const u8) !*Image {
    const image = try ResourceManager.loadImage(
        allocator,
        gfx,
        path,
    );
    return image;
}

/// Free the image memory
pub fn deinit(self: *Image) void {
    // Free the underlying RGBAImage
    self.allocator.free(self.rgba_image.pixels);
    // Free the Image itself
    self.allocator.destroy(self);
}

/// Get a sub-image from this image (doesn't copy pixels, just refers to a region)
pub fn subImage(self: *Image, x: i32, y: i32, width: i32, height: i32) !*Image {
    const sub_image = try self.allocator.create(Image);

    // The sub-image uses the same RGBAImage but with bounds information
    sub_image.* = .{
        .rgba_image = self.rgba_image,
        .allocator = self.allocator,
        .sub_bounds = Rectangle{
            .min = .{ .x = x, .y = y },
            .max = .{ .x = x + width, .y = y + height },
        },
    };

    return sub_image;
}

/// Draw this image onto the destination image at the specified position
pub fn draw(self: *Image, dest: *RGBAImage, options: ?DrawImageOptions) void {
    const opts = options orelse .{};

    // Get source dimensions based on whether this is a sub-image
    const src_bounds = if (self.sub_bounds) |bounds| bounds else self.rgba_image.bounds();
    const src_width = src_bounds.dX();
    const src_height = src_bounds.dY();

    // Get destination bounds
    const dest_bounds = dest.bounds();
    const dest_width = @as(u32, @intCast(dest_bounds.dX()));
    const dest_height = @as(u32, @intCast(dest_bounds.dY()));

    // Calculate destination position with center-based coordinates
    const dest_center_x = @as(f32, @floatFromInt(dest_width)) / 2.0;
    const dest_center_y = @as(f32, @floatFromInt(dest_height)) / 2.0;

    // Apply translation
    const x = @as(i32, @intFromFloat(dest_center_x + opts.center_offset_x - @as(f32, @floatFromInt(src_width)) / 2.0));
    const y = @as(i32, @intFromFloat(dest_center_y + opts.center_offset_y - @as(f32, @floatFromInt(src_height)) / 2.0));

    // Calculate source start position
    const src_start_x = src_bounds.min.x;
    const src_start_y = src_bounds.min.y;

    // Copy pixels with transformation
    var src_y: i32 = 0;
    while (src_y < src_height) : (src_y += 1) {
        var src_x: i32 = 0;
        while (src_x < src_width) : (src_x += 1) {
            const dest_x = x + src_x;
            const dest_y = y + src_y;

            // Skip if outside destination bounds
            if (dest_x < 0 or dest_x >= dest_bounds.max.x or
                dest_y < 0 or dest_y >= dest_bounds.max.y)
            {
                continue;
            }

            // Get source pixel
            const actual_src_x = src_start_x + src_x;
            const actual_src_y = src_start_y + src_y;
            const src_pixel = self.rgba_image.getPixel(@intCast(actual_src_x), @intCast(actual_src_y));

            // Apply color scaling
            var scaled_pixel = src_pixel;
            scaled_pixel.rgba.r = @intFromFloat(@as(f32, @floatFromInt(src_pixel.rgba.r)) * opts.color_scale[0]);
            scaled_pixel.rgba.g = @intFromFloat(@as(f32, @floatFromInt(src_pixel.rgba.g)) * opts.color_scale[1]);
            scaled_pixel.rgba.b = @intFromFloat(@as(f32, @floatFromInt(src_pixel.rgba.b)) * opts.color_scale[2]);
            scaled_pixel.rgba.a = @intFromFloat(@as(f32, @floatFromInt(src_pixel.rgba.a)) * opts.color_scale[3]);

            // Set destination pixel
            dest.setPixel(@intCast(dest_x), @intCast(dest_y), scaled_pixel);
        }
    }
}

/// Draw this image directly to the screen
pub fn drawToScreen(self: *Image, screen: *RGBAImage, options: ?DrawImageOptions) void {
    self.draw(screen, options);
}
