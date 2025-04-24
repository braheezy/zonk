const std = @import("std");
const zonk = @import("zonk");

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

pub fn draw(self: *Paddle, graphics: *zonk.Graphics) void {
    graphics.fillRect(
        self.position[0] - self.size.width / 2,
        self.position[1] - self.size.height / 2,
        self.size.width,
        self.size.height,
        .{ 1.0, 1.0, 1.0, 1.0 },
    );
}

pub fn layout(self: *Paddle, width: usize, height: usize) void {
    _ = self;
    _ = width;
    _ = height;
    // TODO: Add layout handling
}
