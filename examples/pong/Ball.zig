const std = @import("std");
const zonk = @import("zonk");
const image = @import("zpix").image;
const color = @import("color");
const Rectangle = image.Rectangle;
const Drawer = image.Drawer;
const RGBAImage = image.RGBAImage;

const Ball = @This();

// Game state
position: [2]f32,
velocity: [2]f32,
radius: f32 = 10.0,
speed: f32 = 5.0,
is_visible: bool = true,

pub const Config = struct {
    position: [2]f32 = .{ 0.0, 0.0 }, // Start at center
    initial_direction: f32 = -45.0, // Angle in degrees, measured from positive x-axis
};

pub fn create(allocator: std.mem.Allocator, config: Config) !*Ball {
    const ball = try allocator.create(Ball);

    // Convert angle to radians and calculate initial velocity
    const angle_rad = config.initial_direction * std.math.pi / 180.0;
    const initial_velocity = [2]f32{
        @cos(angle_rad) * 5.0, // x component
        @sin(angle_rad) * 5.0, // y component
    };

    ball.* = .{
        .position = config.position,
        .velocity = initial_velocity,
    };
    return ball;
}

pub fn update(self: *Ball) void {
    // Update position based on velocity
    self.position[0] += self.velocity[0];
    self.position[1] += self.velocity[1];
}

pub fn draw(self: *Ball, screen: *RGBAImage) void {
    if (!self.is_visible) return;

    const bounds = screen.bounds();
    const screen_width = @as(u32, @intCast(bounds.dX()));
    const screen_height = @as(u32, @intCast(bounds.dY()));

    // Convert ball position from game coordinates to screen coordinates
    const x = @as(i32, @intFromFloat(self.position[0] + @as(f32, @floatFromInt(screen_width)) / 2.0));
    const y = @as(i32, @intFromFloat(self.position[1] + @as(f32, @floatFromInt(screen_height)) / 2.0));

    // Check if ball is off screen
    if (x < 0 or x >= @as(i32, @intCast(screen_width)) or
        y < 0 or y >= @as(i32, @intCast(screen_height)))
    {
        self.is_visible = false;
        return;
    }

    // Create a rectangle for the ball
    const ball_rect = Rectangle{
        .min = .{ .x = x - @as(i32, @intFromFloat(self.radius)), .y = y - @as(i32, @intFromFloat(self.radius)) },
        .max = .{ .x = x + @as(i32, @intFromFloat(self.radius)), .y = y + @as(i32, @intFromFloat(self.radius)) },
    };

    // Draw the ball as a white filled rectangle (for now, can be changed to circle later)
    var d = Drawer.init(screen);
    const white = color.Color{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } };
    d.fillRect(ball_rect, white);
}

pub fn layout(self: *Ball, width: usize, height: usize) void {
    _ = self;
    _ = width;
    _ = height;
    // Ball doesn't need layout adjustments as it starts in the center
    // and its size is fixed
}
