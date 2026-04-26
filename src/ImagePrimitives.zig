const std = @import("std");
const color = @import("color.zig");

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Rectangle = struct {
    min: Point,
    max: Point,

    pub fn dX(self: Rectangle) i32 {
        return self.max.x - self.min.x;
    }

    pub fn dY(self: Rectangle) i32 {
        return self.max.y - self.min.y;
    }
};

pub const RGBAImage = struct {
    pixels: []u8,
    rect: Rectangle,

    pub fn init(allocator: std.mem.Allocator, rect: Rectangle) !RGBAImage {
        const width = rect.dX();
        const height = rect.dY();
        if (width < 0 or height < 0) return error.InvalidDimensions;

        const len = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
        const pixels = try allocator.alloc(u8, len);
        @memset(pixels, 0);

        return .{
            .pixels = pixels,
            .rect = rect,
        };
    }

    pub fn bounds(self: RGBAImage) Rectangle {
        return self.rect;
    }

    pub fn rgbaAt(self: RGBAImage, x: i32, y: i32) color.RGBA {
        if (!self.contains(x, y)) return .{ .r = 0, .g = 0, .b = 0, .a = 0 };
        const idx = self.pixelIndex(x, y);
        return .{
            .r = self.pixels[idx],
            .g = self.pixels[idx + 1],
            .b = self.pixels[idx + 2],
            .a = self.pixels[idx + 3],
        };
    }

    pub fn setRGBA(self: *RGBAImage, x: i32, y: i32, rgba: color.RGBA) void {
        if (!self.contains(x, y)) return;
        const idx = self.pixelIndex(x, y);
        self.pixels[idx] = rgba.r;
        self.pixels[idx + 1] = rgba.g;
        self.pixels[idx + 2] = rgba.b;
        self.pixels[idx + 3] = rgba.a;
    }

    pub fn writePixels(self: *RGBAImage, pixels: []const u8, region: Rectangle) !void {
        const width = region.dX();
        const height = region.dY();
        if (width < 0 or height < 0) return error.InvalidDimensions;

        const expected_len = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
        if (pixels.len != expected_len) return error.InvalidLength;

        var y: i32 = 0;
        while (y < height) : (y += 1) {
            var x: i32 = 0;
            while (x < width) : (x += 1) {
                const src_idx = @as(usize, @intCast(y * width + x)) * 4;
                self.setRGBA(region.min.x + x, region.min.y + y, .{
                    .r = pixels[src_idx],
                    .g = pixels[src_idx + 1],
                    .b = pixels[src_idx + 2],
                    .a = pixels[src_idx + 3],
                });
            }
        }
    }

    fn contains(self: RGBAImage, x: i32, y: i32) bool {
        return x >= self.rect.min.x and x < self.rect.max.x and
            y >= self.rect.min.y and y < self.rect.max.y;
    }

    fn pixelIndex(self: RGBAImage, x: i32, y: i32) usize {
        const width = self.rect.dX();
        const local_x = x - self.rect.min.x;
        const local_y = y - self.rect.min.y;
        return @as(usize, @intCast(local_y * width + local_x)) * 4;
    }
};

pub const Drawer = struct {
    image: *RGBAImage,

    pub fn init(image: *RGBAImage) Drawer {
        return .{ .image = image };
    }

    pub fn fillRect(self: *Drawer, rect: Rectangle, fill_color: color.Color) void {
        const rgba = fill_color.toRGBA();
        const bounds = self.image.bounds();
        const min_x = @max(rect.min.x, bounds.min.x);
        const min_y = @max(rect.min.y, bounds.min.y);
        const max_x = @min(rect.max.x, bounds.max.x);
        const max_y = @min(rect.max.y, bounds.max.y);

        var y = min_y;
        while (y < max_y) : (y += 1) {
            var x = min_x;
            while (x < max_x) : (x += 1) {
                self.image.setRGBA(x, y, rgba);
            }
        }
    }
};
