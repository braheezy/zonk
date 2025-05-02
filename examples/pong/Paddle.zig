const std = @import("std");
const zonk = @import("zonk");
const image = @import("zpix").image;
const color = @import("color");
const Rectangle = image.Rectangle;
const Drawer = image.Drawer;
const RGBAImage = image.RGBAImage;
const zglfw = zonk.zglfw;

const Controller = enum {
    ai,
    human,
};

const KeyMapping = struct {
    up: zglfw.Key,
    down: zglfw.Key,
};

const Paddle = @This();

// Game state
position: [2]f32,
player_number: u8,
speed: f32 = 6.0,
controller: Controller,
size: struct { width: f32, height: f32 } = .{ .width = 20.0, .height = 100.0 },
initial_position: [2]f32, // Store initial position for reset
screen_height: f32 = 600.0, // Store screen height for boundary checking
keys: KeyMapping, // Store key mappings for this paddle

pub const Config = struct {
    position: [2]f32,
    player_number: u8,
    controller: Controller = .ai,
};

fn getDefaultKeyMapping(player_number: u8) KeyMapping {
    return switch (player_number) {
        1 => .{ // Left paddle - WASD
            .up = .w,
            .down = .s,
        },
        else => .{ // Right paddle - Arrow keys
            .up = .up,
            .down = .down,
        },
    };
}

pub fn create(allocator: std.mem.Allocator, config: Config) !*Paddle {
    const paddle = try allocator.create(Paddle);
    paddle.* = .{
        .position = config.position,
        .player_number = config.player_number,
        .controller = config.controller,
        .initial_position = config.position,
        .screen_height = 600.0,
        .keys = getDefaultKeyMapping(config.player_number),
    };
    return paddle;
}

pub fn update(self: *Paddle) void {
    if (self.controller == .human) {
        var new_y = self.position[1];

        if (zonk.input_state.isKeyDown(self.keys.up)) {
            new_y += self.speed;
        }
        if (zonk.input_state.isKeyDown(self.keys.down)) {
            new_y -= self.speed;
        }

        // Calculate paddle boundaries
        const half_height = self.screen_height / 2.0;
        const paddle_half_height = self.size.height / 2.0;

        // Clamp paddle position to screen boundaries
        new_y = std.math.clamp(new_y, -half_height + paddle_half_height, // Bottom boundary
            half_height - paddle_half_height // Top boundary
        );

        self.position[1] = new_y;
    }
}

pub fn draw(self: *Paddle, screen: *RGBAImage) void {
    const bounds = screen.bounds();
    const screen_width = @as(u32, @intCast(bounds.dX()));
    const screen_height = @as(u32, @intCast(bounds.dY()));

    // Convert paddle position from game coordinates to screen coordinates
    const x = @as(i32, @intFromFloat((self.position[0] + @as(f32, @floatFromInt(screen_width)) / 2.0) - self.size.width / 2.0));
    const y = @as(i32, @intFromFloat((self.position[1] + @as(f32, @floatFromInt(screen_height)) / 2.0) - self.size.height / 2.0));
    const width = @as(i32, @intFromFloat(self.size.width));
    const height = @as(i32, @intFromFloat(self.size.height));

    // Create a rectangle for the paddle
    const paddle_rect = Rectangle{
        .min = .{ .x = x, .y = y },
        .max = .{ .x = x + width, .y = y + height },
    };

    // Create a drawer and draw the paddle as a white rectangle
    var d = Drawer.init(screen);
    const white = color.Color{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } };
    d.fillRect(paddle_rect, white);
}

pub fn layout(self: *Paddle, width: usize, height: usize) void {
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

    // Update screen height for boundary checking
    self.screen_height = @floatFromInt(height);
}

pub fn reset(self: *Paddle) void {
    self.position = self.initial_position;
}
