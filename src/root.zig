const std = @import("std");
pub const zglfw = @import("zglfw");

const image = @import("image");
pub const Game = @import("Game.zig");
pub const InputState = @import("input_state.zig");
pub const Image = @import("Image.zig").Image;
pub const color = @import("color");

const App = @import("App.zig");

pub var input_state: *InputState = undefined;
pub var app: *App = undefined;

// FPS tracking
var frame_times: [120]f32 = undefined;
var frame_time_index: usize = 0;
var frame_time_count: usize = 0;

pub fn getFPS() f32 {
    if (frame_time_count == 0) return 0;

    var sum: f32 = 0;
    const count = @min(frame_time_count, frame_times.len);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        sum += frame_times[i];
    }
    const avg_frame_time = sum / @as(f32, @floatFromInt(count));
    return 1.0 / avg_frame_time;
}

pub const GameConfig = struct {
    title: []const u8 = "Game",
    width: u32 = 800,
    height: u32 = 600,
    vsync: bool = true,
    uncapped_fps: bool = false,
    enable_text_rendering: bool = false,
};

pub fn run(
    comptime T: type,
    instance: *T,
    allocator: std.mem.Allocator,
    config: GameConfig,
) !void {
    // Initialize the game to get layout dimensions first
    var temp_game = Game.init(T, instance);
    const screen_layout = temp_game.layout(config.width, config.height);

    // Create config with layout dimensions for screen buffer
    const screen_config = GameConfig{
        .title = config.title,
        .width = @as(u32, @intCast(screen_layout.width)),
        .height = @as(u32, @intCast(screen_layout.height)),
        .vsync = config.vsync,
        .uncapped_fps = config.uncapped_fps,
        .enable_text_rendering = config.enable_text_rendering,
    };

    app = try App.init(allocator, config, screen_config);
    defer app.deinit();

    app.game = Game.init(T, instance);
    input_state = &app.input;

    const fps = 60;
    const frame_ns = std.time.ns_per_s / fps;
    var timer = try std.time.Timer.start();
    var acc: u64 = 0;

    // Reset FPS tracking
    frame_time_index = 0;
    frame_time_count = 0;

    while (app.isRunning()) {
        zglfw.pollEvents();

        const elapsed = timer.lap();
        acc += elapsed;

        // Track frame time for FPS calculation
        const frame_time_s = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(std.time.ns_per_s));
        frame_times[frame_time_index] = frame_time_s;
        frame_time_index = (frame_time_index + 1) % frame_times.len;
        if (frame_time_count < frame_times.len) {
            frame_time_count += 1;
        }

        // Update input state
        app.input.update();

        // Update timing
        app.total_time += @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(std.time.ns_per_s));
        app.delta_time = @as(f32, @floatFromInt(frame_ns)) / @as(f32, @floatFromInt(std.time.ns_per_s));

        if (app.game) |*game| {
            if (config.uncapped_fps) {
                game.update();
            } else {
                // For fixed FPS, accumulate updates
                while (acc >= frame_ns) : (acc -= frame_ns) {
                    game.update();
                }
            }

            // Layout and draw
            const layout_dim = game.layout(app.width, app.height);
            _ = layout_dim; // Use the layout dimensions if needed
            const screen = app.graphics.getScreenImage();
            game.draw(screen);
            try app.graphics.render();
        }

        // if (config.uncapped_fps) {
        //     // For uncapped FPS, update and render immediately
        //     if (app.game) |*game| {
        //         game.update();
        //         game.layout(app.width, app.height);
        //         game.draw(app.graphics.getScreen());
        //         try app.graphics.render();
        //     }
        // } else {
        //     // For fixed FPS, accumulate updates
        //     while (acc >= frame_ns) : (acc -= frame_ns) {
        //         if (app.game) |*game| {
        //             game.update();
        //         }
        //     }

        //     // Layout and draw
        //     if (app.game) |*game| {
        //         game.layout(app.width, app.height);
        //         game.draw(app.graphics.getScreen());
        //         try app.graphics.render();
        //     }
        // }

        app.window.swapBuffers();

        // Sleep if we're running too fast and not in uncapped mode
        if (!config.uncapped_fps) {
            const frame_time = timer.read();
            if (frame_time < frame_ns) {
                std.time.sleep(frame_ns - frame_time);
            }
        }
    }
}

var buffer: [1024]u8 = undefined;
pub fn print(comptime fmt: []const u8, args: anytype, x: f32, y: f32, text_color: [4]f32) !void {
    if (app.graphics.printer) |*printer| {
        const message = try std.fmt.bufPrint(buffer[0..], fmt, args);

        try printer.text(message, x, y, text_color);
    } else {
        return error.PrinterNotEnabled;
    }
}

pub fn newImageFromImage(allocator: std.mem.Allocator, img: *image.Image) !*Image {
    const size = img.bounds().size();
    const zonk_image = try Image.init(allocator, size.x, size.y);

    const bytes = try imageToBytes(allocator, img);
    const region = image.Rectangle{
        .min = .{ .x = 0, .y = 0 },
        .max = .{ .x = size.x, .y = size.y },
    };
    try zonk_image.writePixels(bytes, region);
    return zonk_image;
}

fn imageToBytes(allocator: std.mem.Allocator, img: *image.Image) ![]u8 {
    const size = img.bounds().size();
    const width = size.x;
    const height = size.y;

    switch (img.*) {
        .RGBA => |i| {
            if (i.pixels.len == width * height * 4) {
                return i.pixels;
            } else {
                return imageToBytesSlow(allocator, img);
            }
        },
        else => {
            return imageToBytesSlow(allocator, img);
        },
    }
}

fn imageToBytesSlow(allocator: std.mem.Allocator, img: *image.Image) ![]u8 {
    const size = img.bounds().size();
    const width = size.x;
    const height = size.y;
    const pixel_buffer = try allocator.alloc(u8, @as(usize, @intCast(width * height * 4)));
    const dst_img = &image.RGBAImage{
        .pixels = pixel_buffer,
        .stride = width * 4,
        .rect = .{
            .min = .{ .x = 0, .y = 0 },
            .max = .{ .x = width, .y = height },
        },
    };

    image.draw(img, dst_img);
    return pixel_buffer;
}
