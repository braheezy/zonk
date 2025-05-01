const std = @import("std");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const zmath = @import("zmath");

const ResourceManager = @import("ResourceManager.zig");
pub const Graphics = @import("Graphics.zig");
pub const Game = @import("Game.zig");
const InputState = @import("input_state.zig").InputState;
const GameConfig = @import("root.zig").GameConfig;

// Vertex format for 2D/2.5D rendering
pub const Vertex2D = struct {
    position: [2]f32,
    color: [4]f32,
    uv: [2]f32,
};

// Uniforms for game rendering
pub const GameUniforms = struct {
    projection: zmath.Mat,
    view: zmath.Mat,
    model: zmath.Mat,
    color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
};

pub const App = @This();

// Core engine state
allocator: std.mem.Allocator,
window: *zglfw.Window,
graphics: *Graphics,
input: InputState,

// Game state
delta_time: f32,
total_time: f32,
game: ?Game = null,

// Window dimensions
width: u32,
height: u32,

pub fn init(allocator: std.mem.Allocator, config: GameConfig) !*App {
    std.debug.print("App.init - initializing GLFW\n", .{});
    try zglfw.init();

    // Create window
    zglfw.windowHint(.client_api, .no_api);
    zglfw.windowHint(.resizable, true);
    const title_sentinel = std.fmt.allocPrintZ(allocator, "{s}", .{config.title}) catch unreachable;
    defer allocator.free(title_sentinel);
    const window = try zglfw.createWindow(
        @intCast(config.width),
        @intCast(config.height),
        title_sentinel,
        null,
    );
    std.debug.print("App.init - window created\n", .{});

    // Create app instance
    const app = try allocator.create(App);
    app.* = .{
        .allocator = allocator,
        .window = window,
        .graphics = undefined,
        .input = try InputState.init(allocator),
        .delta_time = 0,
        .total_time = 0,
        .width = config.width,
        .height = config.height,
    };

    std.debug.print("App.init - creating graphics context\n", .{});
    // Initialize graphics context
    const gfx = try zgpu.GraphicsContext.create(allocator, .{
        .window = window,
        .fn_getTime = @ptrCast(&zglfw.getTime),
        .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),

        // optional fields
        .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
        .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
        .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
        .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
        .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
        .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
    }, .{
        .required_limits = &zgpu.wgpu.RequiredLimits{
            .limits = .{
                .max_vertex_attributes = 3,
                .max_vertex_buffers = 1,
                .max_buffer_size = 100000 * @sizeOf(Graphics.Vertex2D),
                .max_vertex_buffer_array_stride = @sizeOf(Graphics.Vertex2D),
                .max_bind_groups = 1,
                .max_uniform_buffers_per_shader_stage = 1,
                .max_uniform_buffer_binding_size = 256,
            },
        },
    });

    // Initialize graphics system
    app.graphics = try Graphics.init(
        gfx,
        allocator,
        config.width,
        config.height,
    );

    app.createCallbacks();
    std.debug.print("App.init - initialization complete\n", .{});

    return app;
}

fn createCallbacks(self: *App) void {
    // Get pointer to App to pass to callbacks
    zglfw.setWindowUserPointer(self.window, @ptrCast(self));

    _ = zglfw.setKeyCallback(self.window, struct {
        fn cb(window: *zglfw.Window, key: zglfw.Key, scancode: i32, action: zglfw.Action, mods: zglfw.Mods) callconv(.C) void {
            _ = scancode;
            _ = mods;
            const app = window.getUserPointer(App) orelse unreachable;
            app.input.setKeyState(key, action != .release);
        }
    }.cb);

    // _ = zglfw.setCursorPosCallback(self.window, struct {
    //     fn cb(window: *zglfw.Window, xpos: f64, ypos: f64) callconv(.C) void {
    //         // If ImGui is using the mouse, ignore the event
    //         if (zgui.io.getWantCaptureMouse()) return;

    //         const app = window.getUserPointer(App) orelse unreachable;
    //         if (app.drag_state.active) {
    //             // Handle high DPI displays by scaling the mouse position
    //             const scale = window.getContentScale();

    //             const current_mouse_pos: [2]f64 = .{ xpos / scale[0], ypos / scale[1] };
    //             const delta: [2]f64 = .{
    //                 (current_mouse_pos[0] - app.drag_state.start_position[0]) * DragState.sensitivity,
    //                 (current_mouse_pos[1] - app.drag_state.start_position[1]) * DragState.sensitivity,
    //             };
    //             app.camera.angles[0] = app.drag_state.start_camera.angles[0] + @as(f32, @floatCast(delta[0]));
    //             app.camera.angles[1] = app.drag_state.start_camera.angles[1] + @as(f32, @floatCast(delta[1]));
    //             // Clamp to avoid going too far when orbitting up/down
    //             app.camera.angles[1] = zmath.clamp(
    //                 app.camera.angles[1],
    //                 -std.math.pi / 2.0 + 1e-5,
    //                 std.math.pi / 2.0 - 1e-5,
    //             );
    //             app.updateView();

    //             app.drag_state.velocity = .{
    //                 delta[0] - app.drag_state.previous_delta[0],
    //                 delta[1] - app.drag_state.previous_delta[1],
    //             };
    //             app.drag_state.previous_delta = delta;
    //         }
    //     }
    // }.cb);

}

pub fn deinit(self: *App) void {
    self.input.deinit();
    // Cleanup graphics resources
    self.graphics.deinit();

    // Cleanup core resources
    zglfw.destroyWindow(self.window);
    zglfw.terminate();
    self.allocator.destroy(self);
}

pub fn isRunning(self: *App) bool {
    return !self.window.shouldClose() and
        self.window.getKey(.escape) != .press;
}

// pub fn run(
//     comptime T: type,
//     instance: *T,
//     allocator: std.mem.Allocator,
//     config: GameConfig,
// ) !void {
//     const app = try App.init(allocator, config);
//     defer app.deinit();

//     app.game = Game.init(T, instance);

//     const fps = 60;
//     const frame_ns = std.time.ns_per_s / fps;
//     var timer = try std.time.Timer.start();
//     var acc: u64 = 0;

//     while (app.isRunning()) {
//         zglfw.pollEvents();

//         const elapsed = timer.lap();
//         acc += elapsed;

//         // Update input state
//         app.input.update();

//         // Update timing
//         app.total_time += @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(std.time.ns_per_s));
//         app.delta_time = @as(f32, @floatFromInt(frame_ns)) / @as(f32, @floatFromInt(std.time.ns_per_s));

//         // Dispatch fixed-dt updates
//         while (acc >= frame_ns) : (acc -= frame_ns) {
//             if (app.game) |*game| {
//                 game.update();
//             }
//         }

//         // Layout and draw
//         if (app.game) |*game| {
//             game.layout(app.width, app.height);
//             game.draw(app.graphics.getScreen());
//             app.graphics.render();
//         }
//         app.window.swapBuffers();

//         // Sleep if we're running too fast
//         const frame_time = timer.read();
//         if (frame_time < frame_ns) {
//             std.time.sleep(frame_ns - frame_time);
//         }
//     }
// }
