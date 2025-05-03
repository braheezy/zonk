const std = @import("std");
const zonk = @import("zonk");
const image = @import("image");
const PongGame = @import("PongGame.zig");

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
        .enable_text_rendering = true,
    };

    // Configure and run game
    try zonk.run(
        PongGame,
        game,
        allocator,
        config,
    );
}
