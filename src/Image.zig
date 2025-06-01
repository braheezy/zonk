const std = @import("std");
const RGBAImage = @import("image").RGBAImage;
const Rectangle = @import("image").Rectangle;
const zgpu = @import("zgpu");
const ResourceManager = @import("ResourceManager.zig");
const Geom = @import("Geom.zig");
const color = @import("color");

/// Represents a 2D image in the Zonk engine
/// Wraps the RGBAImage type from zpix
pub const Image = @This();

/// The underlying RGBAImage
rgba_image: RGBAImage,
allocator: std.mem.Allocator,
/// Sub-image bounds when this is a sub-image
sub_bounds: ?Rectangle = null,
/// Whether this image owns its pixel data
owns_pixels: bool = true,

/// Options for drawing images
pub const DrawImageOptions = struct {
    geom: Geom = Geom{},
    color_scale: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
};

/// Create a new image with the given dimensions
pub fn init(allocator: std.mem.Allocator, width: i32, height: i32) !*Image {
    const image = try allocator.create(Image);

    const bounds = Rectangle{
        .min = .{ .x = 0, .y = 0 },
        .max = .{ .x = width, .y = height },
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
    // Only free the underlying RGBAImage pixels if we own them
    if (self.owns_pixels) {
        self.allocator.free(self.rgba_image.pixels);
    }
    // Free the Image itself
    self.allocator.destroy(self);
}

/// Get a sub-image from this image (doesn't copy pixels, just refers to a region)
pub fn subImage(self: *Image, rect: Rectangle) !*Image {
    const sub_image = try self.allocator.create(Image);

    // The sub-image uses the same RGBAImage but with bounds information
    sub_image.* = .{
        .rgba_image = self.rgba_image,
        .allocator = self.allocator,
        .sub_bounds = rect,
        .owns_pixels = false, // Sub-images don't own their pixel data
    };

    return sub_image;
}

/// Draw a source image onto this image (Ebiten-style API)
pub fn draw(self: *Image, source: *Image, options: ?DrawImageOptions) void {
    source.drawToDestination(&self.rgba_image, options);
}

/// Draw a source image onto this image (alternative name for compatibility)
pub fn drawImage(self: *Image, source: *Image, options: ?DrawImageOptions) void {
    source.drawToDestination(&self.rgba_image, options);
}

/// Draw this image onto the destination image at the specified position
pub fn drawToDestination(self: *Image, dest: *RGBAImage, options: ?DrawImageOptions) void {
    const opts = options orelse DrawImageOptions{};

    // Get source dimensions based on whether this is a sub-image
    const src_bounds = if (self.sub_bounds) |bounds| bounds else self.rgba_image.bounds();
    const src_width = src_bounds.dX();
    const src_height = src_bounds.dY();

    // Get destination bounds
    const dest_bounds = dest.bounds();

    // Calculate source start position
    const src_start_x = src_bounds.min.x;
    const src_start_y = src_bounds.min.y;

    // Copy pixels with transformation
    var src_y: i32 = 0;
    while (src_y < src_height) : (src_y += 1) {
        var src_x: i32 = 0;
        while (src_x < src_width) : (src_x += 1) {
            // Apply geometry transformation
            const transformed = opts.geom.apply(@as(f32, @floatFromInt(src_x)), @as(f32, @floatFromInt(src_y)));

            const dest_x = @as(i32, @intFromFloat(transformed.x));
            const dest_y = @as(i32, @intFromFloat(transformed.y));

            // Skip if outside destination bounds
            if (dest_x < dest_bounds.min.x or dest_x >= dest_bounds.max.x or
                dest_y < dest_bounds.min.y or dest_y >= dest_bounds.max.y)
            {
                continue;
            }

            // Get source pixel
            const actual_src_x = src_start_x + src_x;
            const actual_src_y = src_start_y + src_y;
            const src_pixel = self.rgba_image.rgbaAt(actual_src_x, actual_src_y);

            // Skip transparent pixels for better blending
            if (src_pixel.a == 0) {
                continue;
            }

            // Apply color scaling
            var scaled_pixel = src_pixel;
            scaled_pixel.r = @intFromFloat(@as(f32, @floatFromInt(src_pixel.r)) * opts.color_scale[0]);
            scaled_pixel.g = @intFromFloat(@as(f32, @floatFromInt(src_pixel.g)) * opts.color_scale[1]);
            scaled_pixel.b = @intFromFloat(@as(f32, @floatFromInt(src_pixel.b)) * opts.color_scale[2]);
            scaled_pixel.a = @intFromFloat(@as(f32, @floatFromInt(src_pixel.a)) * opts.color_scale[3]);

            // Set destination pixel
            dest.setRGBA(dest_x, dest_y, scaled_pixel);
        }
    }
}

pub fn setPixel(self: *Image, x: i32, y: i32, c: color.RGBA) void {
    self.rgba_image.setRGBA(x, y, c);
}

// WritePixels replaces the pixels at the specified region.
pub fn writePixels(self: *Image, pixels: []u8, region: Rectangle) !void {
    const length = @as(usize, @intCast(4 * region.dX() * region.dY()));
    if (length != pixels.len) {
        return error.InvalidLength;
    }

    // Writing one pixel is a special case.
    if (region.dX() == 1 and region.dY() == 1) {
        const width = self.rgba_image.bounds().dX();
        const idx = @as(usize, @intCast(4 * (region.min.y * width + region.min.x)));
        if (idx + 3 < self.rgba_image.pixels.len) {
            self.rgba_image.pixels[idx] = pixels[0];
            self.rgba_image.pixels[idx + 1] = pixels[1];
            self.rgba_image.pixels[idx + 2] = pixels[2];
            self.rgba_image.pixels[idx + 3] = pixels[3];
        }
    } else {
        try self.rgba_image.writePixels(pixels, region);
    }
}

/// Draw this image directly to the screen
pub fn drawToScreen(self: *Image, screen: *RGBAImage, options: ?DrawImageOptions) void {
    self.draw(screen, options);
}
