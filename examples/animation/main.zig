const std = @import("std");
const zonk = @import("zonk");
const Image = zonk.Image;
const color = zonk.color;

const screen_width = 320;
const screen_height = 240;

const frame_ox = 0;
const frame_oy = 32;
const frame_width = 32;
const frame_height = 32;
const frame_count = 8;

pub const AnimationGame = @This();

count: i32 = 0,
runner_image: ?*Image = null,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) AnimationGame {
    return AnimationGame{
        .allocator = allocator,
    };
}

pub fn deinit(self: *AnimationGame) void {
    if (self.runner_image) |img| {
        img.deinit();
    }
}

pub fn start(self: *AnimationGame) !void {
    // Load the runner sprite sheet
    self.runner_image = try Image.fromFile(self.allocator, undefined, "examples/animation/runner.png");
}

pub fn update(self: *AnimationGame) void {
    self.count += 1;
}

pub fn layout(self: *AnimationGame, width: usize, height: usize) zonk.Game.LayoutDim {
    _ = self;
    _ = width;
    _ = height;
    return .{ .width = screen_width, .height = screen_height };
}

pub fn draw(self: *AnimationGame, screen: *Image) void {
    // Clear screen first
    screen.fill(color.RGBA{ .r = 0x80, .g = 0x80, .b = 0xc0, .a = 0xff });

    if (self.runner_image) |runner| {
        // Calculate which frame to show
        const frame_index = @rem(@divTrunc(self.count, 5), frame_count);
        const sx = frame_ox + frame_index * frame_width;
        const sy = frame_oy;

        // Create a sub-image for the current frame
        const frame_image = runner.subImage(.{
            .min = .{ .x = sx, .y = sy },
            .max = .{ .x = sx + frame_width, .y = sy + frame_height },
        }) catch return;
        defer frame_image.deinit();

        var draw_opts = Image.DrawImageOptions{};

        // translate to center sprite, then translate to screen center
        draw_opts.geom.translate(-@as(f32, @floatFromInt(frame_width)) / 2.0, -@as(f32, @floatFromInt(frame_height)) / 2.0);
        draw_opts.geom.translate(@as(f32, @floatFromInt(screen_width)) / 2.0, @as(f32, @floatFromInt(screen_height)) / 2.0);

        // Draw the frame to the screen
        screen.drawImage(frame_image, draw_opts);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var game = AnimationGame.init(allocator);
    defer game.deinit();

    try game.start();

    const config = zonk.GameConfig{
        .title = "Animation Example",
        .width = screen_width * 2,
        .height = screen_height * 2,
        .vsync = true,
        .uncapped_fps = false,
    };

    try zonk.run(AnimationGame, &game, allocator, config);
}
