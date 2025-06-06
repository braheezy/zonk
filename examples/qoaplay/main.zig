const std = @import("std");
const builtin = @import("builtin");
const qoa = @import("qoa");
const zoto = @import("zoto");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

// QOA Reader struct to handle sample data
const QOAReader = struct {
    samples: []const i16,
    pos: usize,
    channels: u8,
    allocator: std.mem.Allocator,

    const Self = @This();
    const ReadError = error{OutOfMemory};

    pub fn read(self: *Self, buf: []u8) ReadError!usize {
        // Calculate how many samples we can read (2 bytes per sample)
        const samples_to_read = buf.len / 2;

        if (self.pos >= self.samples.len) {
            return 0; // EOF
        }

        // Don't read more samples than we have available
        const available_samples = self.samples.len - self.pos;
        const actual_samples_to_read = @min(samples_to_read, available_samples);

        if (actual_samples_to_read == 0) {
            return 0;
        }

        // Convert samples to bytes
        for (0..actual_samples_to_read) |i| {
            if (self.pos >= self.samples.len) {
                return i * 2; // Return bytes written so far
            }

            const sample = self.samples[self.pos];
            buf[i * 2] = @as(u8, @truncate(@as(u16, @bitCast(sample)) & 0xFF));
            buf[i * 2 + 1] = @as(u8, @truncate(@as(u16, @bitCast(sample)) >> 8));
            self.pos += 1;
        }

        return actual_samples_to_read * 2;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }
};

fn newQOAReader(allocator: std.mem.Allocator, samples: []const i16, channels: u8) !*QOAReader {
    const reader = try allocator.create(QOAReader);
    reader.* = QOAReader{
        .samples = samples,
        .pos = 0,
        .channels = channels,
        .allocator = allocator,
    };
    return reader;
}

fn calcSongLength(sample_count: u64, sample_rate: u32) u64 {
    return (sample_count * std.time.ns_per_s) / sample_rate;
}

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

    const data = @embedFile("island_zone.qoa");
    const result = try qoa.decode(allocator, data);
    const samples = result.samples;
    const decoder = result.decoder;
    defer allocator.free(samples);

    std.debug.print("sample_count: {d}\n", .{decoder.sample_count});
    std.debug.print("channels: {d}\n", .{decoder.channels});
    std.debug.print("samplerate: {d}\n", .{decoder.sample_rate});

    const options = zoto.ContextOptions{
        .sample_rate = decoder.sample_rate,
        .channel_count = @intCast(decoder.channels),
        .format = .int16_le,
    };

    const context = try zoto.newContext(allocator, options);
    defer {
        // Give the context time to clean up properly
        std.time.sleep(std.time.ns_per_ms * 100);
        context.deinit();
    }

    context.waitForReady();

    // Create QOA reader
    const qoa_reader = try newQOAReader(allocator, samples, @intCast(decoder.channels));
    defer qoa_reader.deinit();

    // Create AnyReader wrapper
    const any_reader = std.io.AnyReader{
        .context = @ptrCast(qoa_reader),
        .readFn = struct {
            fn read(ctx: *const anyopaque, buffer: []u8) anyerror!usize {
                const self: *QOAReader = @ptrCast(@alignCast(@constCast(ctx)));
                return self.read(buffer);
            }
        }.read,
    };

    // Create and start player
    const player = try context.newPlayer(any_reader);
    defer player.deinit();

    std.debug.print("▶️  Starting QOA playback...\n", .{});
    try player.play();

    // Wait for playback to start
    while (!player.isPlaying()) {
        std.time.sleep(std.time.ns_per_ms * 10);
    }

    // Wait for playback to complete or timeout
    const start_time = std.time.nanoTimestamp();
    const max_wait_time = calcSongLength(decoder.sample_count, decoder.sample_rate);

    while (player.isPlaying()) {
        const elapsed = std.time.nanoTimestamp() - start_time;
        if (elapsed >= max_wait_time) {
            std.debug.print("⏰ Timeout reached, stopping playback\n", .{});
            break;
        }
        std.time.sleep(std.time.ns_per_ms * 50);
    }

    std.debug.print("🏁 QOA playback completed\n", .{});
}
