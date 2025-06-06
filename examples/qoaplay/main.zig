const std = @import("std");
const builtin = @import("builtin");
const qoa = @import("qoa");
const zoto = @import("zoto");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

const freq_c = 523.3;
const freq_e = 659.3;
const freq_g = 784.0;

pub fn main() !void {
    // Memory allocation setup
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
                std.process.exit(0);
            }
        }
    }

    std.debug.print("Testing audio pause and resume functionality...\n", .{});
    std.debug.print("Playing 523.3 Hz sine wave with pause/resume demo...\n", .{});

    const options = zoto.ContextOptions{
        .sample_rate = 48000,
        .channel_count = 2,
        .format = .int16_le,
    };

    const context = try zoto.newContext(allocator, options);
    defer {
        // Give the context time to clean up properly
        std.time.sleep(std.time.ns_per_ms * 100);
        context.deinit();
    }

    context.waitForReady();

    const duration = 6 * std.time.ns_per_s; // 6 seconds total

    try playWithPauseResume(allocator, context, freq_c, duration, options.channel_count, options.format, @intCast(options.sample_rate));

    std.debug.print("Done!\n", .{});
}

fn playWithPauseResume(
    allocator: std.mem.Allocator,
    ctx: *zoto.Context,
    freq: f64,
    duration: usize,
    channel_count: usize,
    format: zoto.Format,
    sample_rate: u32,
) !void {
    // Create the sine wave reader
    const sine_wave = try newSineWave(allocator, freq, duration, channel_count, format, sample_rate);
    defer sine_wave.deinit();

    // Create AnyReader using the explicit type
    const any_reader = std.io.AnyReader{
        .context = @ptrCast(sine_wave),
        .readFn = struct {
            fn read(context: *const anyopaque, buffer: []u8) anyerror!usize {
                const self: *SineWave = @ptrCast(@alignCast(@constCast(context)));
                return self.read(buffer);
            }
        }.read,
    };

    const player = try ctx.newPlayer(any_reader);
    defer player.deinit();

    // Start playing
    std.debug.print("▶️  Starting playback...\n", .{});
    try player.play();

    // Wait for the player to actually start playing
    while (!player.isPlaying()) {
        std.time.sleep(std.time.ns_per_ms * 10);
    }

    // Play for 2 seconds
    std.debug.print("🎵 Playing for 2 seconds...\n", .{});
    std.time.sleep(2 * std.time.ns_per_s);

    // Pause the audio using the context
    std.debug.print("⏸️  Pausing playback...\n", .{});
    player.pause();

    // Wait for pause to take effect
    std.time.sleep(std.time.ns_per_ms * 100);

    std.debug.print("✅ Audio paused using context.pause()\n", .{});

    // Wait 2 seconds while paused
    std.debug.print("🔇 Waiting 2 seconds while paused...\n", .{});
    std.time.sleep(2 * std.time.ns_per_s);

    // Resume playback using the context
    std.debug.print("▶️  Resuming playback...\n", .{});
    try player.play();

    // Wait for resume to take effect
    std.time.sleep(std.time.ns_per_ms * 100);

    std.debug.print("✅ Audio resumed using context.play()\n", .{});

    // Play for remaining time
    std.debug.print("🎵 Playing remainder of audio...\n", .{});

    // Wait for the audio to finish naturally or timeout
    const start_time = std.time.nanoTimestamp();
    const max_wait_time = 10 * std.time.ns_per_s; // 10 second timeout

    while (player.isPlaying()) {
        const elapsed = std.time.nanoTimestamp() - start_time;
        if (elapsed >= max_wait_time) {
            std.debug.print("⏰ Timeout reached, stopping playback\n", .{});
            break;
        }
        std.time.sleep(std.time.ns_per_ms * 50);
    }

    // Give extra time for the audio system to clean up
    std.time.sleep(std.time.ns_per_ms * 500);
    std.debug.print("🏁 Playback completed\n", .{});
}

const SineWave = struct {
    freq: f64,
    length: i64,
    pos: i64,
    channel_count: i32,
    format: zoto.Format,
    sample_rate: u32,
    allocator: std.mem.Allocator,
    sample_count: usize,

    const Self = @This();
    const ReadError = error{OutOfMemory};
    const Reader = std.io.Reader(*Self, ReadError, read);

    pub fn reader(self: *Self) Reader {
        return .{ .context = self };
    }

    pub fn read(self: *Self, buf: []u8) ReadError!usize {
        if (self.pos >= self.length) {
            return 0; // EOF
        }

        // Calculate how many bytes we can provide
        const remaining_bytes = self.length - self.pos;
        const bytes_to_write = @min(buf.len, @as(usize, @intCast(remaining_bytes)));

        // Ensure we write complete samples only
        const bytes_per_sample = formatByteLength(self.format) * @as(usize, @intCast(self.channel_count));
        const complete_samples = bytes_to_write / bytes_per_sample;
        const actual_bytes = complete_samples * bytes_per_sample;

        if (actual_bytes == 0) {
            return 0;
        }

        const length = @as(f64, @floatFromInt(self.sample_rate)) / self.freq;

        // CRITICAL FIX: Calculate sample position once per read() call to maintain phase continuity
        const sample_index = @divTrunc(self.pos, @as(i64, @intCast(bytes_per_sample)));

        switch (self.format) {
            .float32_le => {
                const samples = actual_bytes / bytes_per_sample;
                for (0..samples) |i| {
                    const current_sample_index = sample_index + @as(i64, @intCast(i));
                    const sample = @sin(2.0 * std.math.pi * @as(f64, @floatFromInt(current_sample_index)) / length) * 0.3;
                    const bits = @as(u32, @bitCast(@as(f32, @floatCast(sample))));

                    for (0..@as(usize, @intCast(self.channel_count))) |ch| {
                        const byte_offset = bytes_per_sample * i + 4 * ch;
                        buf[byte_offset] = @as(u8, @truncate(bits));
                        buf[byte_offset + 1] = @as(u8, @truncate(bits >> 8));
                        buf[byte_offset + 2] = @as(u8, @truncate(bits >> 16));
                        buf[byte_offset + 3] = @as(u8, @truncate(bits >> 24));
                    }
                }
            },
            .uint8 => {
                const samples = actual_bytes / bytes_per_sample;
                for (0..samples) |i| {
                    const current_sample_index = sample_index + @as(i64, @intCast(i));
                    const sample = @sin(2.0 * std.math.pi * @as(f64, @floatFromInt(current_sample_index)) / length) * 0.3;
                    const b: u8 = @intFromFloat(sample * 127 + 128);

                    for (0..@as(usize, @intCast(self.channel_count))) |ch| {
                        buf[bytes_per_sample * i + ch] = b;
                    }
                }
            },
            .int16_le => {
                const samples = actual_bytes / bytes_per_sample;
                for (0..samples) |i| {
                    const current_sample_index = sample_index + @as(i64, @intCast(i));
                    const sample = @sin(2.0 * std.math.pi * @as(f64, @floatFromInt(current_sample_index)) / length) * 0.3;
                    const b: i16 = @intFromFloat(sample * 32767);

                    for (0..@as(usize, @intCast(self.channel_count))) |ch| {
                        const byte_offset = bytes_per_sample * i + 2 * ch;
                        buf[byte_offset] = @as(u8, @truncate(@as(u16, @bitCast(b))));
                        buf[byte_offset + 1] = @as(u8, @truncate(@as(u16, @bitCast(b)) >> 8));
                    }
                }
            },
        }

        self.pos += @as(i64, @intCast(actual_bytes));

        return actual_bytes;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }
};

fn formatByteLength(format: zoto.Format) usize {
    return switch (format) {
        .float32_le => 4,
        .uint8 => 1,
        .int16_le => 2,
    };
}

fn newSineWave(allocator: std.mem.Allocator, freq: f64, duration: usize, channel_count: usize, format: zoto.Format, sample_rate: u32) !*SineWave {
    const wave = try allocator.create(SineWave);

    // Calculate length in bytes like Go implementation
    var l = @as(i64, @intCast(channel_count)) * @as(i64, @intCast(formatByteLength(format))) * @as(i64, @intCast(sample_rate)) * @as(i64, @intCast(duration));
    l = @divTrunc(l, @as(i64, @intCast(std.time.ns_per_s)));
    l = @divTrunc(l, 4) * 4; // Align to 4-byte boundary

    wave.* = SineWave{
        .freq = freq,
        .length = l,
        .pos = 0,
        .channel_count = @intCast(channel_count),
        .format = format,
        .sample_rate = sample_rate,
        .allocator = allocator,
        .sample_count = 0,
    };
    return wave;
}
