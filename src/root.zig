const std = @import("std");

pub const GameConfig = struct {
    title: []const u8 = "Game",
    width: u32 = 800,
    height: u32 = 600,
    vsync: bool = true,
};

// pub fn run(
//     comptime T: type,
//     instance: *T,
//     allocator: std.mem.Allocator,
//     config: GameConfig,
// ) !void {}
