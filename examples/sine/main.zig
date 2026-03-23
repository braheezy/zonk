const std = @import("std");
const builtin = @import("builtin");
const zoto = @import("zoto");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

const freq_c = 523.3;

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

    std.debug.print("Testing audio pause and resume functionality...\n", .{});
    std.debug.print("Playing 523.3 Hz sine wave with pause/resume demo...\n", .{});

    const options = zoto.ContextOptions{
        .sample_rate = 48000,
        .channel_count = 2,
        .format = .float32_le,
    };

    const context = try zoto.newContext(allocator, options);
    defer {
        std.Thread.sleep(std.time.ns_per_ms * 100);
        context.deinit();
    }

    context.waitForReady();

    const duration_ns = 6 * std.time.ns_per_s;
    const audio = try buildSineAudio(
        allocator,
        freq_c,
        duration_ns,
        options.channel_count,
        options.sample_rate,
    );
    defer allocator.free(audio);

    try playWithPauseResume(context, audio, duration_ns);

    std.debug.print("Done!\n", .{});
}

fn playWithPauseResume(ctx: *zoto.Context, audio: []align(@alignOf(f32)) u8, duration_ns: u64) !void {
    var reader = std.Io.Reader.fixed(audio);
    const player = try ctx.newPlayer(&reader);
    defer player.deinit();

    std.debug.print("Starting playback...\n", .{});
    try player.play();

    while (!player.isPlaying()) {
        std.Thread.sleep(std.time.ns_per_ms * 10);
    }

    std.debug.print("Playing for 2 seconds...\n", .{});
    std.Thread.sleep(2 * std.time.ns_per_s);

    std.debug.print("Pausing playback...\n", .{});
    player.pause();
    std.Thread.sleep(std.time.ns_per_ms * 100);

    std.debug.print("Audio paused using player.pause()\n", .{});
    std.debug.print("Waiting 2 seconds while paused...\n", .{});
    std.Thread.sleep(2 * std.time.ns_per_s);

    std.debug.print("Resuming playback...\n", .{});
    try player.play();
    std.Thread.sleep(std.time.ns_per_ms * 100);

    std.debug.print("Audio resumed using player.play()\n", .{});
    std.debug.print("Playing remainder of audio...\n", .{});

    const start_time = std.time.nanoTimestamp();
    const max_wait_time = @as(i128, @intCast(duration_ns)) + 2 * std.time.ns_per_s;

    while (player.isPlaying()) {
        const elapsed = std.time.nanoTimestamp() - start_time;
        if (elapsed >= max_wait_time) {
            std.debug.print("Timeout reached, stopping playback\n", .{});
            break;
        }
        std.Thread.sleep(std.time.ns_per_ms * 50);
    }

    std.Thread.sleep(std.time.ns_per_ms * 500);
    std.debug.print("Playback completed\n", .{});
}

fn buildSineAudio(
    allocator: std.mem.Allocator,
    freq: f64,
    duration_ns: u64,
    channel_count: u8,
    sample_rate: u32,
) ![]align(@alignOf(f32)) u8 {
    const frame_count = @as(usize, @intCast((@as(u128, sample_rate) * duration_ns) / std.time.ns_per_s));
    const sample_count = frame_count * channel_count;
    const samples = try allocator.alloc(f32, sample_count);

    const period = @as(f64, @floatFromInt(sample_rate)) / freq;
    for (0..frame_count) |frame_index| {
        const sample = @sin(2.0 * std.math.pi * @as(f64, @floatFromInt(frame_index)) / period) * 0.3;
        const pcm_sample = @as(f32, @floatCast(sample));

        for (0..channel_count) |channel_index| {
            samples[frame_index * channel_count + channel_index] = pcm_sample;
        }
    }

    return std.mem.sliceAsBytes(samples);
}
