const std = @import("std");
const RGBAImage = @import("image").RGBAImage;
const Rectangle = @import("image").Rectangle;
const zgpu = @import("zgpu");
const ResourceManager = @import("ResourceManager.zig");
const Geom = @import("Geom.zig");
const ColorScale = @import("ColorScale.zig");
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
    geom: Geom = .{},
    color_scale: ColorScale = .{},
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
pub fn fromFile(allocator: std.mem.Allocator, path: []const u8) !*Image {
    const image = try ResourceManager.loadImage(
        allocator,
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

    // For simple identity transforms, use fast path
    if (opts.geom.isIdentity()) {
        // Fast path: direct pixel copy
        var src_y: i32 = 0;
        while (src_y < src_height) : (src_y += 1) {
            var src_x: i32 = 0;
            while (src_x < src_width) : (src_x += 1) {
                const dest_x = src_x;
                const dest_y = src_y;

                // Skip if outside destination bounds
                if (dest_x < dest_bounds.min.x or dest_x >= dest_bounds.max.x or
                    dest_y < dest_bounds.min.y or dest_y >= dest_bounds.max.y)
                {
                    continue;
                }

                // Get source pixel - flip Y axis for correct orientation
                const actual_src_x = src_start_x + src_x;
                const actual_src_y = src_start_y + (src_height - 1 - src_y);
                const src_pixel = self.rgba_image.rgbaAt(actual_src_x, actual_src_y);

                // Skip completely transparent pixels
                if (src_pixel.a == 0) {
                    continue;
                }

                // Apply color scaling if needed
                var scaled_pixel = src_pixel;
                if (opts.color_scale.r != 1.0 or opts.color_scale.g != 1.0 or opts.color_scale.b != 1.0 or opts.color_scale.a != 1.0) {
                    scaled_pixel.r = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(src_pixel.r)) * opts.color_scale.r));
                    scaled_pixel.g = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(src_pixel.g)) * opts.color_scale.g));
                    scaled_pixel.b = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(src_pixel.b)) * opts.color_scale.b));
                    scaled_pixel.a = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(src_pixel.a)) * opts.color_scale.a));
                }

                // Alpha blend with destination pixel
                if (scaled_pixel.a == 255) {
                    // Fully opaque, just overwrite
                    dest.setRGBA(dest_x, dest_y, scaled_pixel);
                } else if (scaled_pixel.a > 0) {
                    // Alpha blend: result = src * alpha + dst * (1 - alpha)
                    const dst_pixel = dest.rgbaAt(dest_x, dest_y);
                    const src_alpha = @as(f32, @floatFromInt(scaled_pixel.a)) / 255.0;
                    const inv_alpha = 1.0 - src_alpha;

                    const blended_r = @as(f32, @floatFromInt(scaled_pixel.r)) * src_alpha + @as(f32, @floatFromInt(dst_pixel.r)) * inv_alpha;
                    const blended_g = @as(f32, @floatFromInt(scaled_pixel.g)) * src_alpha + @as(f32, @floatFromInt(dst_pixel.g)) * inv_alpha;
                    const blended_b = @as(f32, @floatFromInt(scaled_pixel.b)) * src_alpha + @as(f32, @floatFromInt(dst_pixel.b)) * inv_alpha;
                    const blended_a = @as(f32, @floatFromInt(scaled_pixel.a)) + @as(f32, @floatFromInt(dst_pixel.a)) * inv_alpha;

                    const result_pixel = color.RGBA{
                        .r = @intFromFloat(@min(255.0, blended_r)),
                        .g = @intFromFloat(@min(255.0, blended_g)),
                        .b = @intFromFloat(@min(255.0, blended_b)),
                        .a = @intFromFloat(@min(255.0, blended_a)),
                    };

                    dest.setRGBA(dest_x, dest_y, result_pixel);
                }
                // Skip completely transparent pixels (a == 0)
            }
        }
    } else {
        // Transform path: Use backward mapping to avoid gaps
        // Calculate the bounding box of the transformed source in destination space
        const corners = [_][2]f32{
            .{ 0, 0 },
            .{ @floatFromInt(src_width - 1), 0 },
            .{ 0, @floatFromInt(src_height - 1) },
            .{ @floatFromInt(src_width - 1), @floatFromInt(src_height - 1) },
        };

        var min_x: f32 = std.math.floatMax(f32);
        var max_x: f32 = -std.math.floatMax(f32);
        var min_y: f32 = std.math.floatMax(f32);
        var max_y: f32 = -std.math.floatMax(f32);

        for (corners) |corner| {
            const transformed = opts.geom.apply(corner[0], corner[1]);
            min_x = @min(min_x, transformed.x);
            max_x = @max(max_x, transformed.x);
            min_y = @min(min_y, transformed.y);
            max_y = @max(max_y, transformed.y);
        }

        const bbox_min_x = @max(@as(f32, @floatFromInt(dest_bounds.min.x)), min_x);
        const bbox_max_x = @min(@as(f32, @floatFromInt(dest_bounds.max.x - 1)), max_x);
        const bbox_min_y = @max(@as(f32, @floatFromInt(dest_bounds.min.y)), min_y);
        const bbox_max_y = @min(@as(f32, @floatFromInt(dest_bounds.max.y - 1)), max_y);

        // Sample the destination region and use inverse mapping
        var dest_y = @as(i32, @intFromFloat(bbox_min_y));
        const max_dest_y = @as(i32, @intFromFloat(bbox_max_y));
        while (dest_y <= max_dest_y) : (dest_y += 1) {
            var dest_x = @as(i32, @intFromFloat(bbox_min_x));
            const max_dest_x = @as(i32, @intFromFloat(bbox_max_x));
            while (dest_x <= max_dest_x) : (dest_x += 1) {
                // Use inverse transformation to find source pixel
                const src_coord = inverseTransform(&opts.geom, @floatFromInt(dest_x), @floatFromInt(dest_y));

                // Check if the source coordinate is within bounds
                if (src_coord.x >= 0 and src_coord.x < @as(f32, @floatFromInt(src_width)) and
                    src_coord.y >= 0 and src_coord.y < @as(f32, @floatFromInt(src_height)))
                {
                    // Sample the source pixel (nearest neighbor for now)
                    const src_x = @as(i32, @intFromFloat(@round(src_coord.x)));
                    const src_y = @as(i32, @intFromFloat(@round(src_coord.y)));

                    // Get source pixel - flip Y axis for correct orientation
                    const actual_src_x = src_start_x + src_x;
                    const actual_src_y = src_start_y + (src_height - 1 - src_y);
                    const src_pixel = self.rgba_image.rgbaAt(actual_src_x, actual_src_y);

                    // Skip completely transparent pixels
                    if (src_pixel.a == 0) {
                        continue;
                    }

                    // Apply color scaling if needed
                    var scaled_pixel = src_pixel;
                    if (opts.color_scale.r != 1.0 or opts.color_scale.g != 1.0 or opts.color_scale.b != 1.0 or opts.color_scale.a != 1.0) {
                        scaled_pixel.r = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(src_pixel.r)) * opts.color_scale.r));
                        scaled_pixel.g = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(src_pixel.g)) * opts.color_scale.g));
                        scaled_pixel.b = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(src_pixel.b)) * opts.color_scale.b));
                        scaled_pixel.a = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(src_pixel.a)) * opts.color_scale.a));
                    }

                    // Alpha blend with destination pixel
                    if (scaled_pixel.a == 255) {
                        // Fully opaque, just overwrite
                        dest.setRGBA(dest_x, dest_y, scaled_pixel);
                    } else if (scaled_pixel.a > 0) {
                        // Alpha blend: result = src * alpha + dst * (1 - alpha)
                        const dst_pixel = dest.rgbaAt(dest_x, dest_y);
                        const src_alpha = @as(f32, @floatFromInt(scaled_pixel.a)) / 255.0;
                        const inv_alpha = 1.0 - src_alpha;

                        const blended_r = @as(f32, @floatFromInt(scaled_pixel.r)) * src_alpha + @as(f32, @floatFromInt(dst_pixel.r)) * inv_alpha;
                        const blended_g = @as(f32, @floatFromInt(scaled_pixel.g)) * src_alpha + @as(f32, @floatFromInt(dst_pixel.g)) * inv_alpha;
                        const blended_b = @as(f32, @floatFromInt(scaled_pixel.b)) * src_alpha + @as(f32, @floatFromInt(dst_pixel.b)) * inv_alpha;
                        const blended_a = @as(f32, @floatFromInt(scaled_pixel.a)) + @as(f32, @floatFromInt(dst_pixel.a)) * inv_alpha;

                        const result_pixel = color.RGBA{
                            .r = @intFromFloat(@min(255.0, blended_r)),
                            .g = @intFromFloat(@min(255.0, blended_g)),
                            .b = @intFromFloat(@min(255.0, blended_b)),
                            .a = @intFromFloat(@min(255.0, blended_a)),
                        };

                        dest.setRGBA(dest_x, dest_y, result_pixel);
                    }
                    // Skip completely transparent pixels (a == 0)
                }
            }
        }
    }
}

// Helper function to compute inverse transformation
fn inverseTransform(geom: *const Geom, x: f32, y: f32) struct { x: f32, y: f32 } {
    // For a 2D affine transformation matrix:
    // [x']   [a  c  tx] [x]
    // [y'] = [b  d  ty] [y]
    // [1 ]   [0  0  1 ] [1]
    //
    // The inverse is:
    // [x]   [d  -c  (c*ty - d*tx)] [x']
    // [y] = [-b  a  (b*tx - a*ty)] [y']
    // [1]   [0   0   (a*d - b*c) ] [1 ]
    //
    // Divided by the determinant (a*d - b*c)

    const det = geom.a * geom.d - geom.b * geom.c;
    if (@abs(det) < 1e-10) {
        // Singular matrix, return original point
        return .{ .x = x, .y = y };
    }

    const inv_det = 1.0 / det;

    const tx_adj = x - geom.tx;
    const ty_adj = y - geom.ty;

    return .{
        .x = (geom.d * tx_adj - geom.c * ty_adj) * inv_det,
        .y = (-geom.b * tx_adj + geom.a * ty_adj) * inv_det,
    };
}

pub fn setPixel(self: *Image, x: i32, y: i32, c: color.RGBA) void {
    self.rgba_image.setRGBA(x, y, c);
}

/// Fill the entire image with a solid color
pub fn fill(self: *Image, c: color.RGBA) void {
    const bounds = self.rgba_image.bounds();
    var y: i32 = bounds.min.y;
    while (y < bounds.max.y) : (y += 1) {
        var x: i32 = bounds.min.x;
        while (x < bounds.max.x) : (x += 1) {
            self.rgba_image.setRGBA(x, y, c);
        }
    }
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
    self.drawToDestination(screen, options);
}
