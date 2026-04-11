const std = @import("std");
const assert = std.debug.assert;
const zonk = @import("zonk");
const PongGame = @import("PongGame.zig");

pub fn main() !void {
    // Memory allocation setup
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer assert(debug_allocator.deinit() == .ok);
    const gpa = debug_allocator.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

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
