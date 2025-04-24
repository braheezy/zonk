const std = @import("std");
const zonk = @import("zonk");

const Paddle = @import("Paddle.zig");
// const Ball = @import("Ball.zig");

const PongGame = struct {
    allocator: std.mem.Allocator,
    gfx: *zonk.Graphics,
    left_paddle: *Paddle,
    right_paddle: *Paddle,

    pub fn init(allocator: std.mem.Allocator, gfx: *zonk.Graphics) !*PongGame {
        const game = try allocator.create(PongGame);

        // Create paddles
        const left_paddle = try Paddle.create(allocator, .{
            .position = .{ -350.0, 0.0 },
            .player_number = 1,
        });

        const right_paddle = try Paddle.create(allocator, .{
            .position = .{ 350.0, 0.0 },
            .player_number = 2,
        });

        game.* = .{
            .allocator = allocator,
            .left_paddle = left_paddle,
            .right_paddle = right_paddle,
            .gfx = gfx,
        };

        return game;
    }

    pub fn deinit(self: *PongGame) void {
        self.allocator.destroy(self.left_paddle);
        self.allocator.destroy(self.right_paddle);
        self.allocator.destroy(self);
    }

    pub fn update(self: *PongGame) void {
        self.left_paddle.update();
        self.right_paddle.update();
    }

    pub fn draw(self: *PongGame) void {
        self.left_paddle.draw(self.gfx);
        self.right_paddle.draw(self.gfx);
    }

    pub fn layout(self: *PongGame, width: usize, height: usize) void {
        std.debug.print("pong: layout game\n", .{});

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

    std.debug.print("init app\n", .{});
    var app = try zonk.App.init(allocator, .{
        .title = "Pong",
        .width = 800,
        .height = 600,
        .vsync = true,
    });
    defer app.deinit();

    std.debug.print("init game\n", .{});
    // Create game instance
    var game = try PongGame.init(allocator, app.graphics);
    defer game.deinit();

    // Configure and run game
    try app.run(PongGame, game);
}
