const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const zigaudio = @import("zigaudio");
const zoto = @import("zoto");

fn calcSongLength(frame_count: usize, sample_rate: u32) i128 {
    return @as(i128, @intCast((@as(u128, frame_count) * std.time.ns_per_s) / sample_rate));
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer assert(debug_allocator.deinit() == .ok);
    const gpa = debug_allocator.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const data = @embedFile("island_zone.qoa");
    const decoder = try zigaudio.fromMemory(gpa, data);
    defer decoder.deinit(gpa);

    std.debug.print("sample_count: {d}\n", .{decoder.info.total_frames});
    std.debug.print("channels: {d}\n", .{decoder.info.channels});
    std.debug.print("samplerate: {d}\n", .{decoder.info.sample_rate});

    const options = zoto.ContextOptions{
        .sample_rate = decoder.info.sample_rate,
        .channel_count = decoder.info.channels,
        .format = .float32_le,
    };

    const context = try zoto.newContext(gpa, options);
    defer {
        std.Io.sleep(io, .fromNanoseconds(std.time.ns_per_ms * 100), .awake) catch {};
        context.deinit();
    }

    context.waitForReady();

    var adapter = zigaudio.DecoderReader.init(decoder);
    const player = try context.newPlayer(adapter.reader());
    defer player.deinit();

    std.debug.print("Starting QOA playback...\n", .{});
    try player.play();

    while (!player.isPlaying()) {
        std.Io.sleep(io, .fromNanoseconds(std.time.ns_per_ms * 10), .awake) catch {};
    }

    const start_time = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    const max_wait_time = calcSongLength(decoder.info.total_frames, decoder.info.sample_rate);

    while (player.isPlaying()) {
        const elapsed = std.Io.Timestamp.now(io, .awake).toNanoseconds() - start_time;
        if (elapsed >= max_wait_time) {
            std.debug.print("Timeout reached, stopping playback\n", .{});
            break;
        }
        std.Io.sleep(io, .fromNanoseconds(std.time.ns_per_ms * 50), .awake) catch {};
    }

    std.debug.print("QOA playback completed\n", .{});
}
