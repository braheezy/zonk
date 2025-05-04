const std = @import("std");
const zonk = @import("zonk");
const image = @import("zpix").image;
const color = @import("color");
const Rectangle = image.Rectangle;
const Drawer = image.Drawer;
const RGBAImage = image.RGBAImage;
const Paddle = @import("Paddle.zig");

const Ball = @This();

// Game state
position: [2]f32,
velocity: [2]f32,
radius: f32 = 10.0,
speed: f32 = 5.0,
is_visible: bool = true,
screen_height: f32 = 600.0, // Default screen height, will be updated in layout
player_scored: ?u8 = null, // Player 1 or 2 who scored, or null if no one scored yet

pub const Config = struct {
    position: [2]f32 = .{ 0.0, 0.0 }, // Start at center
    initial_direction: ?f32 = null, // If null, will use random diagonal direction
};

// Helper function to check collision with a paddle
fn checkPaddleCollision(self: *Ball, paddle: *const Paddle) bool {
    // Get paddle bounds
    const paddle_half_width = paddle.size.width / 2.0;
    const paddle_half_height = paddle.size.height / 2.0;
    const paddle_left = paddle.position[0] - paddle_half_width;
    const paddle_right = paddle.position[0] + paddle_half_width;
    const paddle_top = paddle.position[1] + paddle_half_height;
    const paddle_bottom = paddle.position[1] - paddle_half_height;

    // Get ball bounds
    const ball_left = self.position[0] - self.radius;
    const ball_right = self.position[0] + self.radius;
    const ball_top = self.position[1] + self.radius;
    const ball_bottom = self.position[1] - self.radius;

    // Check for overlap in both x and y axes
    const x_overlap = ball_right >= paddle_left and ball_left <= paddle_right;
    const y_overlap = ball_top >= paddle_bottom and ball_bottom <= paddle_top;

    return x_overlap and y_overlap;
}

// Helper function to generate random diagonal velocity
fn generateRandomVelocity(random: std.Random) [2]f32 {
    // First randomly choose between left (-1) and right (1)
    const x_dir: f32 = if (random.boolean()) 1.0 else -1.0;
    // Then randomly choose between up (1) and down (-1)
    const y_dir: f32 = if (random.boolean()) 1.0 else -1.0;

    // Set diagonal velocity with normalized components to maintain constant speed
    const diagonal_factor = @sqrt(0.5); // 1/√2 to normalize diagonal vector
    return .{
        x_dir * 5.0 * diagonal_factor,
        y_dir * 5.0 * diagonal_factor,
    };
}

pub fn create(allocator: std.mem.Allocator, config: Config) !*Ball {
    const ball = try allocator.create(Ball);
    var prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const random = prng.random();

    // Calculate initial velocity
    var initial_velocity: [2]f32 = undefined;
    if (config.initial_direction) |direction| {
        const angle_rad = direction * std.math.pi / 180.0;
        initial_velocity = .{
            @cos(angle_rad) * 5.0,
            @sin(angle_rad) * 5.0,
        };
    } else {
        initial_velocity = generateRandomVelocity(random);
    }

    ball.* = .{
        .position = config.position,
        .velocity = initial_velocity,
        .radius = 10.0,
        .speed = 5.0,
        .is_visible = true,
        .screen_height = 600.0,
    };
    return ball;
}

pub fn reset(self: *Ball) !void {
    var prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const random = prng.random();

    // Reset position to center
    self.position = .{ 0.0, 0.0 };
    // Generate new random velocity
    self.velocity = generateRandomVelocity(random);
    // Ensure ball is visible
    self.is_visible = true;
    // Reset player_scored flag
    self.player_scored = null;
}

pub fn update(self: *Ball, left_paddle: *const Paddle, right_paddle: *const Paddle) void {
    // Calculate next position
    const next_x = self.position[0] + self.velocity[0];
    const next_y = self.position[1] + self.velocity[1];

    // Check for ceiling and floor collisions
    const half_height = self.screen_height / 2.0;
    if (next_y + self.radius >= half_height or next_y - self.radius <= -half_height) {
        // Bounce by inverting y velocity
        self.velocity[1] = -self.velocity[1];
    }

    // Update position
    self.position[0] = next_x;
    self.position[1] = next_y;

    // Check for paddle collisions
    if (checkPaddleCollision(self, left_paddle) or checkPaddleCollision(self, right_paddle)) {
        // Bounce by inverting x velocity
        self.velocity[0] = -self.velocity[0];

        // Move ball slightly away from paddle to prevent sticking
        self.position[0] += if (self.velocity[0] > 0) self.radius else -self.radius;
    }
}

pub fn draw(self: *Ball, screen: *RGBAImage) void {
    if (!self.is_visible) return;

    const bounds = screen.bounds();
    const screen_width = @as(u32, @intCast(bounds.dX()));
    const screen_height = @as(u32, @intCast(bounds.dY()));

    // Convert ball position from game coordinates to screen coordinates
    const x = @as(i32, @intFromFloat(self.position[0] + @as(f32, @floatFromInt(screen_width)) / 2.0));
    const y = @as(i32, @intFromFloat(self.position[1] + @as(f32, @floatFromInt(screen_height)) / 2.0));

    // Check if ball is off screen horizontally (scoring)
    if (x < 0) {
        // Ball went off the left side, player 2 (right) scores
        self.is_visible = false;
        self.player_scored = 2;
        return;
    } else if (x >= @as(i32, @intCast(screen_width))) {
        // Ball went off the right side, player 1 (left) scores
        self.is_visible = false;
        self.player_scored = 1;
        return;
    }

    // Check if ball is off screen vertically
    if (y < 0 or y >= @as(i32, @intCast(screen_height))) {
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
    _ = width;
    // Update the screen height for collision detection
    self.screen_height = @floatFromInt(height);
}
