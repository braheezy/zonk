const std = @import("std");
const zonk = @import("zonk");
const PongGame = @import("PongGame.zig");

pub fn main(process_init: std.process.Init) !void {
    const gpa = process_init.gpa;
    const io = process_init.io;

    // Create game instance
    var game = try PongGame.init(gpa, io);
    defer game.deinit();
    const config = zonk.GameConfig{
        .title = "Pong",
        .width = 800,
        .height = 600,
        .vsync = true,
        .enable_text_rendering = false,
    };

    // Configure and run game
    try zonk.run(
        PongGame,
        game,
        gpa,
        io,
        config,
    );
}
