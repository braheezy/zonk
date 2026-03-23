const std = @import("std");
const builtin = @import("builtin");
const zigaudio = @import("zigaudio");
const zoto = @import("zoto");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

fn calcSongLength(frame_count: usize, sample_rate: u32) i128 {
    return @as(i128, @intCast((@as(u128, frame_count) * std.time.ns_per_s) / sample_rate));
}

pub fn main() !void {
    const allocator, const is_debug = gpa: {
        if (builtin.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer {
        if (is_debug) {
            if (debug_allocator.deinit() == .leak) {
                std.process.exit(1);
            }
        }
    }

    const data = @embedFile("island_zone.qoa");
    const decoder = try zigaudio.fromMemory(allocator, data);
    defer decoder.deinit(allocator);

    std.debug.print("sample_count: {d}\n", .{decoder.info.total_frames});
    std.debug.print("channels: {d}\n", .{decoder.info.channels});
    std.debug.print("samplerate: {d}\n", .{decoder.info.sample_rate});

    const options = zoto.ContextOptions{
        .sample_rate = decoder.info.sample_rate,
        .channel_count = decoder.info.channels,
        .format = .float32_le,
    };

    const context = try zoto.newContext(allocator, options);
    defer {
        std.Thread.sleep(std.time.ns_per_ms * 100);
        context.deinit();
    }

    context.waitForReady();

    var adapter = zigaudio.DecoderReader.init(decoder);
    const player = try context.newPlayer(adapter.reader());
    defer player.deinit();

    std.debug.print("Starting QOA playback...\n", .{});
    try player.play();

    while (!player.isPlaying()) {
        std.Thread.sleep(std.time.ns_per_ms * 10);
    }

    const start_time = std.time.nanoTimestamp();
    const max_wait_time = calcSongLength(decoder.info.total_frames, decoder.info.sample_rate);

    while (player.isPlaying()) {
        const elapsed = std.time.nanoTimestamp() - start_time;
        if (elapsed >= max_wait_time) {
            std.debug.print("Timeout reached, stopping playback\n", .{});
            break;
        }
        std.Thread.sleep(std.time.ns_per_ms * 50);
    }

    std.debug.print("QOA playback completed\n", .{});
}
