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

pub fn init(allocator: std.mem.Allocator, window_config: GameConfig, screen_config: GameConfig) !*App {
    std.debug.print("App.init - initializing GLFW\n", .{});
    try zglfw.init();

    // Create window with window_config dimensions
    zglfw.windowHint(.client_api, .no_api);
    zglfw.windowHint(.resizable, false);
    const title_sentinel = std.fmt.allocPrintZ(allocator, "{s}", .{window_config.title}) catch unreachable;
    defer allocator.free(title_sentinel);
    const window = try zglfw.createWindow(
        @intCast(window_config.width),
        @intCast(window_config.height),
        title_sentinel,
        null,
    );
    std.debug.print("App.init - window created\n", .{});

    // Create app instance with window dimensions
    const app = try allocator.create(App);
    app.* = .{
        .allocator = allocator,
        .window = window,
        .graphics = undefined,
        .input = try InputState.init(allocator),
        .delta_time = 0,
        .total_time = 0,
        .width = window_config.width,
        .height = window_config.height,
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

    // Initialize graphics system with screen_config dimensions (logical screen size)
    app.graphics = try Graphics.init(
        gfx,
        allocator,
        screen_config.width,
        screen_config.height,
    );

    if (window_config.enable_text_rendering) {
        try enableTextRendering(app);
    }

    app.createCallbacks();
    std.debug.print("App.init - initialization complete\n", .{});

    return app;
}

pub fn enableTextRendering(self: *App) !void {
    const content_scale_xy = self.window.getContentScale();
    std.debug.print("Pixel scale: (x: {d}, y: {d})\n", .{ content_scale_xy[0], content_scale_xy[1] });
    std.debug.assert(content_scale_xy[0] == content_scale_xy[1]); // Require square pixels.
    const dpr: u32 = @intFromFloat(@round(content_scale_xy[0])); // Round to full pixels.

    try self.graphics.enableTextRendering(dpr);
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
