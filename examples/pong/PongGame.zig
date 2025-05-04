const zonk = @import("zonk");
const std = @import("std");
const image = @import("image");
const Paddle = @import("Paddle.zig");
const Ball = @import("Ball.zig");
const color = @import("color");
const Rectangle = image.Rectangle;
const Drawer = image.Drawer;

const yellow = [4]f32{ 1.0, 1.0, 0.0, 1.0 };
const white = [4]f32{ 1.0, 1.0, 1.0, 1.0 };
const padding_top = 100;

pub const PongGame = @This();

allocator: std.mem.Allocator,
left_paddle: *Paddle,
right_paddle: *Paddle,
ball: *Ball,
game_over: bool = false,
score_left: u32 = 0,
score_right: u32 = 0,
window_width: usize = 0,
window_height: usize = 0,

pub fn init(allocator: std.mem.Allocator) !*PongGame {
    const game = try allocator.create(PongGame);

    // Create paddles with initial positions
    const left_paddle = try Paddle.create(allocator, .{
        .position = .{ -300.0, 0.0 }, // Will be adjusted by layout
        .player_number = 1,
        .controller = .human, // Left paddle uses WASD
    });

    const right_paddle = try Paddle.create(allocator, .{
        .position = .{ 300.0, 0.0 }, // Will be adjusted by layout
        .player_number = 2,
        .controller = .ai, // Right paddle uses arrow keys
    });

    // Create ball with default configuration (starts in center)
    const ball = try Ball.create(allocator, .{});

    game.* = .{
        .allocator = allocator,
        .left_paddle = left_paddle,
        .right_paddle = right_paddle,
        .ball = ball,
        .score_left = 0,
        .score_right = 0,
    };

    return game;
}

pub fn deinit(self: *PongGame) void {
    self.allocator.destroy(self.left_paddle);
    self.allocator.destroy(self.right_paddle);
    self.allocator.destroy(self.ball);
    self.allocator.destroy(self);
}

pub fn update(self: *PongGame) void {
    // If game is over, only allow reset
    if (self.game_over) {
        if (zonk.input_state.isKeyDown(.space)) {
            self.reset() catch unreachable;
            self.game_over = false;
        }
        return;
    }
    // Check for game reset
    if (zonk.input_state.isKeyDown(.space)) {
        self.reset() catch unreachable;
    }
    self.left_paddle.update(self.ball);
    self.right_paddle.update(self.ball);
    self.ball.update(self.left_paddle, self.right_paddle);
    // If the ball is not visible, end the game
    if (!self.ball.is_visible) {
        self.game_over = true;
    }
}

pub fn reset(self: *PongGame) !void {
    self.left_paddle.reset();
    self.right_paddle.reset();
    try self.ball.reset();
    self.game_over = false;
}

fn drawDottedLine(self: *PongGame, screen: *image.RGBAImage) void {
    _ = self;
    const bounds = screen.bounds();
    const width = bounds.dX();
    const height = bounds.dY();

    const center_x = @divFloor(width, 2);
    const dot_height = 10;
    const gap_height = 10;

    var d = Drawer.init(screen);
    const white_color = color.Color{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } };

    var y: usize = 0;
    while (y < height) {
        // Draw a dot segment
        const dot_end = @min(y + dot_height, @as(usize, @intCast(height)));

        // Create a rectangle for the dot segment
        const dot_rect = Rectangle{
            .min = .{ .x = center_x - 1, .y = @intCast(y) },
            .max = .{ .x = center_x + 1, .y = @intCast(dot_end) },
        };

        d.fillRect(dot_rect, white_color);

        // Skip gap
        y = dot_end + gap_height;
    }
}

pub fn draw(self: *PongGame, screen: *image.RGBAImage) void {
    if (self.game_over) {
        // Draw dark red background
        screen.clear(.{ .rgba = .{ .r = 80, .g = 0, .b = 0, .a = 255 } });
    } else {
        // Clear screen to black
        screen.clear(.{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 } });

        // Draw dotted line down the middle
        self.drawDottedLine(screen);
    }

    // Draw both paddles and ball
    self.left_paddle.draw(screen);
    self.right_paddle.draw(screen);
    self.ball.draw(screen);

    const center_x: f32 = @floatFromInt(self.window_width / 2);
    zonk.print("{d}", .{self.score_left}, center_x - 100, padding_top, white) catch unreachable;
    zonk.print("{d}", .{self.score_right}, center_x + 100, padding_top, white) catch unreachable;

    // Draw FPS counter at bottom left corner with absolute coordinates
    zonk.print("fps: {d:02}", .{zonk.getFPS()}, 50, @floatFromInt(self.window_height - 50), yellow) catch unreachable;
}

pub fn layout(self: *PongGame, width: usize, height: usize) void {
    self.window_width = width;
    self.window_height = height;
    self.left_paddle.layout(width, height);
    self.right_paddle.layout(width, height);
    self.ball.layout(width, height);
}
