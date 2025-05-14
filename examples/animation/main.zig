const std = @import("std");
const zonk = @import("zonk");
const image = @import("image");

pub fn main() !void {
    // Memory allocation setup
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer if (gpa.deinit() == .leak) {
        std.process.exit(1);
    };

    var game = Game{};

    try zonk.run(Game, &game, allocator, .{});
}

const Game = struct {
    count: usize = 0,

    pub fn layout(self: *Game, width: usize, height: usize) void {
        _ = self;
        _ = width;
        _ = height;
    }

    pub fn update(self: *Game) void {
        self.count += 1;
    }
};
