# Zonk

A 2D game library for Zig inspired by [Ebiten](https://ebitengine.org/).

## Features

- Hardware-accelerated 2D rendering via WebGPU
- Input handling (keyboard, mouse)
- Image loading and manipulation (PNG, JPEG)
- Text rendering with FreeType and HarfBuzz
- Fixed timestep game loop (60 FPS default)
- Optional uncapped framerate

## Integration

Add to your `build.zig.zon`:

```console
zig fetch --save git+https://github.com/braheezy/zonk
```

Include in your `build.zig`:

```zig
const zonk_dep = b.dependency("zonk", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zonk", zonk_dep.module("zonk"));
```

## Architecture

Zonk implements the Ebiten core concept of separating game logic from rendering:

1. `update()` - Game logic, called every frame
2. `draw(screen)` - Rendering, called after update
3. `layout(width, height)` - Window resize handling

Implement a struct with these methods and `zonk` will call them for you.

### Game Interface

```zig
const YourGame = struct {
    // State fields here

    pub fn update(self: *YourGame) void {
        // Update game state
    }

    pub fn draw(self: *YourGame, screen: *image.RGBAImage) void {
        // Render to screen buffer
    }

    pub fn layout(self: *YourGame, width: usize, height: usize) void {
        // Handle resizing
    }
};
```

### Running Your Game

```zig
pub fn main() !void {
    var game = YourGame{};

    try zonk.run(
        YourGame,
        &game,
        std.heap.page_allocator,
        .{
            .title = "Your Game",
            .width = 800,
            .height = 600,
            .vsync = true,
            .uncapped_fps = false,
            .enable_text_rendering = true,
        },
    );
}
```

### Rendering

Zonk uses the [zpix](https://github.com/braheezy/zpix) library for color support and image operations:

```zig
// Clear screen
screen.clear(.{ .rgba = .{ .r = 0, .g = 0, .b = 0, .a = 255 } });

// Draw rectangles
var d = Drawer.init(screen);
const rect = Rectangle{
    .min = .{ .x = 10, .y = 10 },
    .max = .{ .x = 50, .y = 50 },
};
d.fillRect(rect, color.Color{ .rgba = .{ .r = 255, .g = 0, .b = 0, .a = 255 } });

// Render text
zonk.print("Score: {d}", .{score}, 10, 10, [4]f32{ 1.0, 1.0, 1.0, 1.0 }) catch unreachable;
```

### Input Handling

```zig
// Check key state
if (zonk.input_state.isKeyDown(.space)) {
    // Space bar is pressed
}

// Check previous frame state
if (zonk.input_state.isKeyJustPressed(.enter)) {
    // Enter key was just pressed this frame
}
```

## Examples

The Pong example in `examples/pong` demonstrates core Zonk concepts including:

- Game loop implementation
- Collision detection
- Input handling
- Rendering and text display

Run it with `zig build pong`.

## Attribution

The text rendering comes from [`zig-text-rendering`](https://github.com/tchayen/zig-text-rendering), thank you for your work **tchayen**!

The contents of `pkg/` are from Ghostty because they are the most mature project that maintains these packages for the latest Zig. They say this about the `pkg` directory:

> If you want to use them, you can copy and paste them into your project.

Very generous of the Ghostty team, thank you!
