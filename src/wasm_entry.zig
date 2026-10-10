const std = @import("std");
const zemscripten = @import("zemscripten");
const app_main = @import("app_main");

extern fn emscripten_get_now() f64;

pub const panic = zemscripten.panic;

pub const std_options = std.Options{
    .logFn = zemscripten.log,
};

export fn main() c_int {
    const gpa = std.heap.c_allocator;

    const argv = [_][*:0]const u8{"zonk"};
    const environ: std.process.Environ.Block = .empty;

    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer arena_allocator.deinit();

    var environ_map = std.process.Environ.createMap(.{ .block = environ }, gpa) catch |err| {
        std.log.err("failed to parse environment variables: {t}", .{err});
        return 1;
    };
    defer environ_map.deinit();

    const preopens = std.process.Preopens.init(arena_allocator.allocator()) catch |err| {
        std.log.err("failed to init preopens: {t}", .{err});
        return 1;
    };

    app_main.main(.{
        .minimal = .{
            .args = .{ .vector = argv[0..] },
            .environ = .{ .block = environ },
        },
        .arena = &arena_allocator,
        .gpa = gpa,
        .io = wasmIo(),
        .environ_map = &environ_map,
        .preopens = preopens,
    }) catch |err| {
        std.log.err("main failed: {t}", .{err});
        return 1;
    };

    return 0;
}

var wasm_vtable: std.Io.VTable = undefined;
var wasm_vtable_init = false;

fn wasmIo() std.Io {
    if (!wasm_vtable_init) {
        wasm_vtable = std.Io.failing.vtable.*;
        wasm_vtable.now = wasmNow;
        wasm_vtable.clockResolution = wasmClockResolution;
        wasm_vtable.sleep = wasmSleep;
        wasm_vtable_init = true;
    }

    return .{
        .userdata = null,
        .vtable = &wasm_vtable,
    };
}

fn wasmNow(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
    return .{
        .nanoseconds = @intFromFloat(emscripten_get_now() * @as(f64, @floatFromInt(std.time.ns_per_ms))),
    };
}

fn wasmClockResolution(_: ?*anyopaque, _: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
    return .fromMilliseconds(1);
}

fn wasmSleep(_: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
    const duration = switch (timeout) {
        .none => return,
        .duration => |d| d.raw,
        .deadline => |d| d.durationFromNow(wasmIo()).raw,
    };
    if (duration.nanoseconds <= 0) return;

    const ms = @max(1, @divTrunc(duration.nanoseconds, std.time.ns_per_ms));
    zemscripten.emscripten_sleep(@intCast(ms));
}
