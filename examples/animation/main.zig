const std = @import("std");
const zonk = @import("zonk");
const image = @import("image");
const Image = zonk.Image;

pub fn main() !void {
    // Memory allocation setup
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer if (gpa.deinit() == .leak) {
        std.process.exit(1);
    };

    var game = try Game.init(allocator);
    defer game.deinit();

    try zonk.run(Game, &game, allocator, .{
        .title = "Zonk Animation Example",
        .width = 320,
        .height = 240,
    });
}

const Game = struct {
    allocator: std.mem.Allocator,
    count: usize = 0,
    runner_image: ?*Image = null,

    pub fn init(allocator: std.mem.Allocator) !Game {
        return Game{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Game) void {
        if (self.runner_image) |img| {
            img.deinit();
        }
    }

    pub fn layout(self: *Game, width: usize, height: usize) void {
        _ = self;
        _ = width;
        _ = height;
    }

    pub fn update(self: *Game) void {
        self.count += 1;
    }

    pub fn draw(self: *Game, screen: *image.RGBAImage) void {
        // Clear screen to black
        screen.clear(.{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 } });

        // Load the runner image if it hasn't been loaded yet
        if (self.runner_image == null) {
            // In a real implementation, you would load a runner.png file
            // Here we create a simple colored rectangle as a placeholder
            self.runner_image = Image.init(self.allocator, 256, 128) catch return;

            // Fill with a simple pattern for demonstration
            const bounds = self.runner_image.?.rgba_image.bounds();
            for (0..@intCast(bounds.dY())) |y| {
                for (0..@intCast(bounds.dX())) |x| {
                    // Create a simple sprite sheet pattern
                    // 8 frames of 32x32 pixels in a single row at y=32
                    const frame_x = x % 32;
                    const frame_index = x / 32;
                    const color = if (y >= 32 and y < 64) switch (frame_index % 8) {
                        0 => .{ .r = 255, .g = 0, .b = 0, .a = 255 }, // Red
                        1 => .{ .r = 255, .g = 127, .b = 0, .a = 255 }, // Orange
                        2 => .{ .r = 255, .g = 255, .b = 0, .a = 255 }, // Yellow
                        3 => .{ .r = 0, .g = 255, .b = 0, .a = 255 }, // Green
                        4 => .{ .r = 0, .g = 0, .b = 255, .a = 255 }, // Blue
                        5 => .{ .r = 75, .g = 0, .b = 130, .a = 255 }, // Indigo
                        6 => .{ .r = 148, .g = 0, .b = 211, .a = 255 }, // Violet
                        7 => .{ .r = 255, .g = 255, .b = 255, .a = 255 }, // White
                        else => .{ .r = 0, .g = 0, .b = 0, .a = 0 },
                    } else .{ .r = 64, .g = 64, .b = 64, .a = 128 };

                    // Draw a small white dot in the corner of each frame to make it obvious when it changes
                    const is_corner = (frame_x < 3) and (y >= 32 and y < 35);
                    const actual_color = if (is_corner)
                        .{ .r = 255, .g = 255, .b = 255, .a = 255 }
                    else
                        color;

                    self.runner_image.?.rgba_image.setPixel(@intCast(x), @intCast(y), .{ .rgba = actual_color });
                }
            }
        }

        // Animation parameters
        const frame_width: i32 = 32;
        const frame_height: i32 = 32;
        const frame_offset_y: i32 = 32;
        const frame_count: i32 = 8;

        // Calculate which frame to display based on count
        const i = @as(i32, @intCast((self.count / 5) % @as(usize, @intCast(frame_count))));
        const frame_offset_x = i * frame_width;

        // Create a sub-image for the current animation frame
        const frame = self.runner_image.?.subImage(frame_offset_x, frame_offset_y, frame_width, frame_height) catch return;
        defer self.allocator.destroy(frame); // Only destroy the sub-image reference, not the pixels

        // Draw the current frame centered on screen
        frame.drawToScreen(screen, .{
            .tx = 0, // Center X
            .ty = 0, // Center Y
        });

        // Draw frame count
        zonk.print("Frame: {d}", .{i}, 10, 10, .{ .rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 } }) catch {};
    }
};
