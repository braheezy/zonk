const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const zonk = @import("zonk");

const screen_width = 640;
const screen_height = 480;

var test_image: *zonk.Image = undefined;

const BlurGame = struct {
    pub fn update(_: *BlurGame) void {}
    pub fn layout(_: *BlurGame, _: usize, _: usize) zonk.Game.LayoutDim {
        return .{ .width = screen_width, .height = screen_height };
    }
    pub fn draw(_: *BlurGame, screen: *zonk.Image) void {
        var op1 = zonk.Image.DrawImageOptions{};
        op1.geom.translate(0, 0);
        screen.drawImage(test_image, op1);

        var layers: u8 = 0;
        var j: isize = -3;
        while (j <= 3) : (j += 1) {
            var i: isize = -3;
            while (i <= 3) : (i += 1) {
                var op2 = zonk.Image.DrawImageOptions{};
                op2.geom.translate(@floatFromInt(i), @floatFromInt(244 + j));
                layers += 1;
                op2.color_scale.scaleAlpha(1.0 / @as(f32, @floatFromInt(layers)));
                screen.drawImage(test_image, op2);
            }
        }
    }
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer assert(debug_allocator.deinit() == .ok);
    const gpa = debug_allocator.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const config = zonk.GameConfig{
        .title = "Blur Example",
        .width = screen_width,
        .height = screen_height,
    };

    var game = BlurGame{};
    test_image = try zonk.Image.fromFile(gpa, io, "examples/blur/image.png");

    // Debug: Print image dimensions
    const bounds = test_image.rgba_image.bounds();
    std.debug.print("Loaded image: {}x{}\n", .{ bounds.dX(), bounds.dY() });
    std.debug.print("Screen size: {}x{}\n", .{ screen_width, screen_height });

    defer test_image.deinit(); // Clean up the image

    try zonk.run(BlurGame, &game, gpa, io, config);
}
