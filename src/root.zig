const std = @import("std");
const zglfw = @import("zglfw");

pub const Game = @import("Game.zig");
pub const InputState = @import("input_state.zig");

pub var input_state: *InputState = undefined;

const App = @import("App.zig");

pub const GameConfig = struct {
    title: []const u8 = "Game",
    width: u32 = 800,
    height: u32 = 600,
    vsync: bool = true,
};

pub fn run(
    comptime T: type,
    instance: *T,
    allocator: std.mem.Allocator,
    config: GameConfig,
) !void {
    var app = try App.init(allocator, config);
    defer app.deinit();

    app.game = Game.init(T, instance);
    input_state = &app.input;

    const fps = 60;
    const frame_ns = std.time.ns_per_s / fps;
    var timer = try std.time.Timer.start();
    var acc: u64 = 0;

    while (app.isRunning()) {
        zglfw.pollEvents();

        const elapsed = timer.lap();
        acc += elapsed;

        // Update input state
        app.input.update();

        // Update timing
        app.total_time += @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(std.time.ns_per_s));
        app.delta_time = @as(f32, @floatFromInt(frame_ns)) / @as(f32, @floatFromInt(std.time.ns_per_s));

        // Dispatch fixed-dt updates
        while (acc >= frame_ns) : (acc -= frame_ns) {
            if (app.game) |*game| {
                game.update();
            }
        }

        // Layout and draw
        if (app.game) |*game| {
            game.layout(app.width, app.height);
            game.draw(app.graphics.getScreen());
            app.graphics.render();
        }
        app.window.swapBuffers();

        // Sleep if we're running too fast
        const frame_time = timer.read();
        if (frame_time < frame_ns) {
            std.time.sleep(frame_ns - frame_time);
        }
    }
}
