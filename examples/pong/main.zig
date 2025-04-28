const std = @import("std");
const zonk = @import("zonk");
const image = @import("image");

const Paddle = @import("Paddle.zig");
// const Ball = @import("Ball.zig");

const PongGame = struct {
    allocator: std.mem.Allocator,
    left_paddle: *Paddle,
    right_paddle: *Paddle,

    pub fn init(allocator: std.mem.Allocator) !*PongGame {
        const game = try allocator.create(PongGame);

        // Create paddles with initial positions
        const left_paddle = try Paddle.create(allocator, .{
            .position = .{ -300.0, 0.0 }, // Will be adjusted by layout
            .player_number = 1,
        });

        const right_paddle = try Paddle.create(allocator, .{
            .position = .{ 300.0, 0.0 }, // Will be adjusted by layout
            .player_number = 2,
        });

        game.* = .{
            .allocator = allocator,
            .left_paddle = left_paddle,
            .right_paddle = right_paddle,
        };

        return game;
    }

    pub fn deinit(self: *PongGame) void {
        self.allocator.destroy(self.left_paddle);
        self.allocator.destroy(self.right_paddle);
        self.allocator.destroy(self);
    }

    pub fn update(self: *PongGame) void {
        std.debug.print("PongGame.update\n", .{});
        self.left_paddle.update();
        self.right_paddle.update();
    }

    pub fn draw(self: *PongGame, screen: *image.RGBAImage) void {
        // Clear screen to black
        screen.clear(.{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 } });

        // Draw both paddles
        self.left_paddle.draw(screen);
        self.right_paddle.draw(screen);
    }

    pub fn layout(self: *PongGame, width: usize, height: usize) void {
        self.left_paddle.layout(width, height);
        self.right_paddle.layout(width, height);
    }
};

pub fn main() !void {
    // Memory allocation setup
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer if (gpa.deinit() == .leak) {
        std.process.exit(1);
    };

    // Create game instance
    var game = try PongGame.init(allocator);
    defer game.deinit();
    const config = zonk.GameConfig{
        .title = "Pong",
        .width = 800,
        .height = 600,
        .vsync = true,
    };

    // Configure and run game
    try zonk.run(
        PongGame,
        game,
        allocator,
        config,
    );
}
