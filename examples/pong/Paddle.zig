const std = @import("std");
const zonk = @import("zonk");
const image = @import("image");
const color = @import("color");
const Paddle = @This();

// Game state
position: [2]f32,
player_number: u8,
speed: f32 = 400.0,
size: struct { width: f32, height: f32 } = .{ .width = 20.0, .height = 100.0 },

pub const Config = struct {
    position: [2]f32,
    player_number: u8,
};

pub fn create(allocator: std.mem.Allocator, config: Config) !*Paddle {
    const paddle = try allocator.create(Paddle);
    paddle.* = .{
        .position = config.position,
        .player_number = config.player_number,
    };
    return paddle;
}

pub fn update(self: *Paddle) void {
    _ = self;
    // TODO: Add input handling
}

pub fn draw(self: *Paddle, screen: *image.Image) void {
    const bounds = screen.bounds();
    const screen_width = @as(u32, @intCast(bounds.dX()));
    const screen_height = @as(u32, @intCast(bounds.dY()));

    // Convert paddle position from game coordinates to screen coordinates
    const x = @as(i32, @intFromFloat((self.position[0] + @as(f32, @floatFromInt(screen_width)) / 2.0) - self.size.width / 2.0));
    const y = @as(i32, @intFromFloat((self.position[1] + @as(f32, @floatFromInt(screen_height)) / 2.0) - self.size.height / 2.0));
    const width = @as(i32, @intFromFloat(self.size.width));
    const height = @as(i32, @intFromFloat(self.size.height));

    // Draw paddle as a white rectangle
    var py: i32 = y;
    while (py < y + height) : (py += 1) {
        var px: i32 = x;
        while (px < x + width) : (px += 1) {
            if (px >= 0 and px < bounds.max.x and py >= 0 and py < bounds.max.y) {
                // Create a white color using the image library's Color type
                const white = color.Color{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } };
                screen.RGBA.setRGBA(px, py, white);
            }
        }
    }
}

pub fn layout(self: *Paddle, width: usize, height: usize) void {
    // Update Y position to be centered vertically
    self.position[1] = 0; // Keep vertical center position

    // Update X position based on player number and window width
    const padding = 50.0; // Distance from screen edge
    if (self.player_number == 1) {
        // Left paddle
        self.position[0] = -@as(f32, @floatFromInt(width)) / 2.0 + padding;
    } else {
        // Right paddle
        self.position[0] = @as(f32, @floatFromInt(width)) / 2.0 - padding;
    }

    // Scale paddle size based on screen height
    self.size.height = @as(f32, @floatFromInt(height)) / 6.0; // Paddle takes up 1/6th of screen height
    self.size.width = 20.0; // Fixed width
}
