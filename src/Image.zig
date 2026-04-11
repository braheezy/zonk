const std = @import("std");
const image = @import("ImagePrimitives.zig");
const RGBAImage = image.RGBAImage;
const Rectangle = image.Rectangle;
const ResourceManager = @import("ResourceManager.zig");
const Geom = @import("Geom.zig");
const ColorScale = @import("ColorScale.zig");
const color = @import("color.zig");

const Self = @This();

rgba_image: RGBAImage,
allocator: std.mem.Allocator,
sub_bounds: ?Rectangle = null,
owns_pixels: bool = true,

pub const DrawImageOptions = struct {
    geom: Geom = .{},
    color_scale: ColorScale = .{},
};

pub fn init(allocator: std.mem.Allocator, width: i32, height: i32) !*Self {
    const image_instance = try allocator.create(Self);
    const bounds = Rectangle{
        .min = .{ .x = 0, .y = 0 },
        .max = .{ .x = width, .y = height },
    };

    image_instance.* = .{
        .rgba_image = try RGBAImage.init(allocator, bounds),
        .allocator = allocator,
    };

    return image_instance;
}

pub fn fromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*Self {
    return ResourceManager.loadImage(allocator, io, path);
}

pub fn deinit(self: *Self) void {
    if (self.owns_pixels) self.allocator.free(self.rgba_image.pixels);
    self.allocator.destroy(self);
}

pub fn subImage(self: *Self, rect: Rectangle) !*Self {
    const sub_image = try self.allocator.create(Self);
    sub_image.* = .{
        .rgba_image = self.rgba_image,
        .allocator = self.allocator,
        .sub_bounds = rect,
        .owns_pixels = false,
    };
    return sub_image;
}

pub fn drawImage(self: *Self, source: *Self, options: ?DrawImageOptions) void {
    source.drawToDestination(&self.rgba_image, options);
}

pub fn drawToDestination(self: *Self, dest: *RGBAImage, options: ?DrawImageOptions) void {
    const opts = options orelse DrawImageOptions{};
    const src_bounds = if (self.sub_bounds) |bounds| bounds else self.rgba_image.bounds();
    const src_width = src_bounds.dX();
    const src_height = src_bounds.dY();
    const dest_bounds = dest.bounds();
    const src_start_x = src_bounds.min.x;
    const src_start_y = src_bounds.min.y;

    if (opts.geom.isIdentity()) {
        var src_y: i32 = 0;
        while (src_y < src_height) : (src_y += 1) {
            var src_x: i32 = 0;
            while (src_x < src_width) : (src_x += 1) {
                const dest_x = src_x;
                const dest_y = src_y;

                if (dest_x < dest_bounds.min.x or dest_x >= dest_bounds.max.x or
                    dest_y < dest_bounds.min.y or dest_y >= dest_bounds.max.y)
                {
                    continue;
                }

                const actual_src_x = src_start_x + src_x;
                const actual_src_y = src_start_y + (src_height - 1 - src_y);
                const src_pixel = self.rgba_image.rgbaAt(actual_src_x, actual_src_y);
                if (src_pixel.a == 0) continue;

                var scaled_pixel = src_pixel;
                if (opts.color_scale.r != 1.0 or opts.color_scale.g != 1.0 or opts.color_scale.b != 1.0 or opts.color_scale.a != 1.0) {
                    scaled_pixel.r = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(src_pixel.r)) * opts.color_scale.r));
                    scaled_pixel.g = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(src_pixel.g)) * opts.color_scale.g));
                    scaled_pixel.b = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(src_pixel.b)) * opts.color_scale.b));
                    scaled_pixel.a = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(src_pixel.a)) * opts.color_scale.a));
                }

                if (scaled_pixel.a == 255) {
                    dest.setRGBA(dest_x, dest_y, scaled_pixel);
                } else if (scaled_pixel.a > 0) {
                    const dst_pixel = dest.rgbaAt(dest_x, dest_y);
                    const src_alpha = @as(f32, @floatFromInt(scaled_pixel.a)) / 255.0;
                    const inv_alpha = 1.0 - src_alpha;

                    dest.setRGBA(dest_x, dest_y, .{
                        .r = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(scaled_pixel.r)) * src_alpha + @as(f32, @floatFromInt(dst_pixel.r)) * inv_alpha)),
                        .g = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(scaled_pixel.g)) * src_alpha + @as(f32, @floatFromInt(dst_pixel.g)) * inv_alpha)),
                        .b = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(scaled_pixel.b)) * src_alpha + @as(f32, @floatFromInt(dst_pixel.b)) * inv_alpha)),
                        .a = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(scaled_pixel.a)) + @as(f32, @floatFromInt(dst_pixel.a)) * inv_alpha)),
                    });
                }
            }
        }
        return;
    }

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

    var dest_y = @as(i32, @intFromFloat(bbox_min_y));
    const max_dest_y = @as(i32, @intFromFloat(bbox_max_y));
    while (dest_y <= max_dest_y) : (dest_y += 1) {
        var dest_x = @as(i32, @intFromFloat(bbox_min_x));
        const max_dest_x = @as(i32, @intFromFloat(bbox_max_x));
        while (dest_x <= max_dest_x) : (dest_x += 1) {
            const src_coord = inverseTransform(&opts.geom, @floatFromInt(dest_x), @floatFromInt(dest_y));
            if (src_coord.x >= 0 and src_coord.x < @as(f32, @floatFromInt(src_width)) and
                src_coord.y >= 0 and src_coord.y < @as(f32, @floatFromInt(src_height)))
            {
                const src_x = @as(i32, @intFromFloat(@round(src_coord.x)));
                const src_y = @as(i32, @intFromFloat(@round(src_coord.y)));
                const actual_src_x = src_start_x + src_x;
                const actual_src_y = src_start_y + (src_height - 1 - src_y);
                const src_pixel = self.rgba_image.rgbaAt(actual_src_x, actual_src_y);
                if (src_pixel.a == 0) continue;

                var scaled_pixel = src_pixel;
                if (opts.color_scale.r != 1.0 or opts.color_scale.g != 1.0 or opts.color_scale.b != 1.0 or opts.color_scale.a != 1.0) {
                    scaled_pixel.r = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(src_pixel.r)) * opts.color_scale.r));
                    scaled_pixel.g = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(src_pixel.g)) * opts.color_scale.g));
                    scaled_pixel.b = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(src_pixel.b)) * opts.color_scale.b));
                    scaled_pixel.a = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(src_pixel.a)) * opts.color_scale.a));
                }

                if (scaled_pixel.a == 255) {
                    dest.setRGBA(dest_x, dest_y, scaled_pixel);
                } else if (scaled_pixel.a > 0) {
                    const dst_pixel = dest.rgbaAt(dest_x, dest_y);
                    const src_alpha = @as(f32, @floatFromInt(scaled_pixel.a)) / 255.0;
                    const inv_alpha = 1.0 - src_alpha;

                    dest.setRGBA(dest_x, dest_y, .{
                        .r = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(scaled_pixel.r)) * src_alpha + @as(f32, @floatFromInt(dst_pixel.r)) * inv_alpha)),
                        .g = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(scaled_pixel.g)) * src_alpha + @as(f32, @floatFromInt(dst_pixel.g)) * inv_alpha)),
                        .b = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(scaled_pixel.b)) * src_alpha + @as(f32, @floatFromInt(dst_pixel.b)) * inv_alpha)),
                        .a = @intFromFloat(@min(255.0, @as(f32, @floatFromInt(scaled_pixel.a)) + @as(f32, @floatFromInt(dst_pixel.a)) * inv_alpha)),
                    });
                }
            }
        }
    }
}

fn inverseTransform(geom: *const Geom, x: f32, y: f32) struct { x: f32, y: f32 } {
    const det = geom.a * geom.d - geom.b * geom.c;
    if (@abs(det) < 1e-10) return .{ .x = x, .y = y };

    const inv_det = 1.0 / det;
    const tx_adj = x - geom.tx;
    const ty_adj = y - geom.ty;

    return .{
        .x = (geom.d * tx_adj - geom.c * ty_adj) * inv_det,
        .y = (-geom.b * tx_adj + geom.a * ty_adj) * inv_det,
    };
}

pub fn setPixel(self: *Self, x: i32, y: i32, c: color.RGBA) void {
    self.rgba_image.setRGBA(x, y, c);
}

pub fn fill(self: *Self, c: color.RGBA) void {
    const bounds = self.rgba_image.bounds();
    var y: i32 = bounds.min.y;
    while (y < bounds.max.y) : (y += 1) {
        var x: i32 = bounds.min.x;
        while (x < bounds.max.x) : (x += 1) {
            self.rgba_image.setRGBA(x, y, c);
        }
    }
}

pub fn writePixels(self: *Self, pixels: []u8, region: Rectangle) !void {
    const length = @as(usize, @intCast(4 * region.dX() * region.dY()));
    if (length != pixels.len) return error.InvalidLength;

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

pub fn drawToScreen(self: *Self, screen: *RGBAImage, options: ?DrawImageOptions) void {
    self.drawToDestination(screen, options);
}
