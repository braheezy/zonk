const std = @import("std");
const builtin = @import("builtin");
const qoa = @import("qoa");
const zoto = @import("zoto");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
pub fn main() !void {
    // Memory allocation setup
    const allocator, const is_debug = gpa: {
        if (builtin.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        if (debug_allocator.deinit() == .leak) {
            std.process.exit(1);
        }
    };

    const data = @embedFile("test.qoa");
    const result = try qoa.decode(allocator, data);
    const samples = result.samples;
    const decoder = result.decoder;
    defer allocator.free(samples);

    std.debug.print("sample_count: {d}\n", .{decoder.sample_count});
    std.debug.print("channels: {d}\n", .{decoder.channels});
    std.debug.print("samplerate: {d}\n", .{decoder.sample_rate});

    zoto.printOSVersion();
    zoto.playAudio("kameks-theme.flac");

    // print samples to file
    // const file = try std.fs.cwd().createFile("samples.txt", .{});
    // defer file.close();
    // for (samples) |sample| {
    //     try std.fmt.formatInt(sample, 10, .lower, .{}, file.writer());
    //     try file.writeAll("\n");
    // }
}
