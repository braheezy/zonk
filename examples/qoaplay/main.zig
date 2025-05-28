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
    defer {
        if (is_debug) {
            if (debug_allocator.deinit() == .leak) {
                std.process.exit(1);
            }
        }
    }

    std.debug.print("Playing 440Hz sine wave for 3 seconds...\n", .{});

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

    const freq = 440.0; // A note (more audible)
    const duration = 3 * std.time.ns_per_s;

    try playAndWait(allocator, context, freq, duration, options.channel_count, options.format, @intCast(options.sample_rate));

    std.debug.print("Done!\n", .{});
}

fn playAndWait(
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

    try player.play();

    // Wait for the player to actually start playing
    while (!player.isPlaying()) {
        std.time.sleep(std.time.ns_per_ms * 10);
    }

    // Wait for the full duration of the audio
    const start_time = std.time.nanoTimestamp();

    while (player.isPlaying()) {
        const elapsed = std.time.nanoTimestamp() - start_time;

        if (elapsed >= duration) {
            break;
        }
        std.time.sleep(std.time.ns_per_ms * 50);
    }

    // Wait for any remaining audio to finish playing
    while (player.isPlaying()) {
        std.time.sleep(std.time.ns_per_ms * 10);
    }

    // Give extra time for the audio system to clean up
    std.time.sleep(std.time.ns_per_ms * 500);
}

const SineWave = struct {
    freq: f64,
    duration_ns: u64,
    start_time: i128,
    channel_count: u8,
    format: zoto.Format,
    sample_rate: u32,
    allocator: std.mem.Allocator,
    sample_position: u64,

    const Self = @This();
    const ReadError = error{};
    const Reader = std.io.Reader(*Self, ReadError, read);

    pub fn reader(self: *Self) Reader {
        return .{ .context = self };
    }

    pub fn read(self: *Self, buf: []u8) ReadError!usize {
        // Check if we've exceeded the duration
        const current_time = std.time.nanoTimestamp();
        const elapsed = current_time - self.start_time;
        if (elapsed >= self.duration_ns) {
            return 0;
        }

        const bytes_per_sample = formatByteLength(self.format) * @as(usize, self.channel_count);

        // Generate as much as requested, but align to sample boundaries
        var bytes_to_generate = buf.len;
        bytes_to_generate = (bytes_to_generate / bytes_per_sample) * bytes_per_sample;

        if (bytes_to_generate == 0) {
            return 0;
        }

        const samples_to_generate = bytes_to_generate / bytes_per_sample;
        const samples_per_cycle = @as(f64, @floatFromInt(self.sample_rate)) / self.freq;

        switch (self.format) {
            .float32_le => {
                var i: usize = 0;
                while (i < samples_to_generate) : (i += 1) {
                    const sample_index = self.sample_position + i;
                    const phase = 2.0 * std.math.pi * @as(f64, @floatFromInt(sample_index)) / samples_per_cycle;
                    const sample = @sin(phase) * 0.95; // Maximum safe volume
                    const bits = @as(u32, @bitCast(@as(f32, @floatCast(sample))));

                    var ch: usize = 0;
                    while (ch < self.channel_count) : (ch += 1) {
                        const byte_offset = i * bytes_per_sample + ch * 4;
                        buf[byte_offset] = @as(u8, @truncate(bits));
                        buf[byte_offset + 1] = @as(u8, @truncate(bits >> 8));
                        buf[byte_offset + 2] = @as(u8, @truncate(bits >> 16));
                        buf[byte_offset + 3] = @as(u8, @truncate(bits >> 24));
                    }
                }
            },
            .uint8 => {
                var i: usize = 0;
                while (i < samples_to_generate) : (i += 1) {
                    const sample_index = self.sample_position + i;
                    const phase = 2.0 * std.math.pi * @as(f64, @floatFromInt(sample_index)) / samples_per_cycle;
                    const sample = @sin(phase) * 0.95; // Maximum safe volume
                    const b: u8 = @intFromFloat(sample * 127.0 + 128.0);

                    var ch: usize = 0;
                    while (ch < self.channel_count) : (ch += 1) {
                        buf[i * bytes_per_sample + ch] = b;
                    }
                }
            },
            .int16_le => {
                var i: usize = 0;
                while (i < samples_to_generate) : (i += 1) {
                    const sample_index = self.sample_position + i;
                    const phase = 2.0 * std.math.pi * @as(f64, @floatFromInt(sample_index)) / samples_per_cycle;
                    const sample = @sin(phase) * 0.95; // Maximum safe volume, continuous sine wave
                    const b: i16 = @intFromFloat(sample * 32767.0);

                    var ch: usize = 0;
                    while (ch < self.channel_count) : (ch += 1) {
                        const byte_offset = i * bytes_per_sample + ch * 2;
                        buf[byte_offset] = @as(u8, @truncate(@as(u16, @bitCast(b))));
                        buf[byte_offset + 1] = @as(u8, @truncate(@as(u16, @bitCast(b)) >> 8));
                    }
                }
            },
        }

        self.sample_position += samples_to_generate;
        return bytes_to_generate;
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
    wave.* = SineWave{
        .freq = freq,
        .duration_ns = @intCast(duration),
        .start_time = std.time.nanoTimestamp(),
        .channel_count = @intCast(channel_count),
        .format = format,
        .sample_rate = sample_rate,
        .allocator = allocator,
        .sample_position = 0,
    };
    return wave;
}
