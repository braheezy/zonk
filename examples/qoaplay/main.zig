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
            // if (debug_allocator.deinit() == .leak) {
            //     std.process.exit(0);
            // }
        }
    }

    std.debug.print("Playing 440Hz sine wave for 2 seconds...\n", .{});

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

    const freq = 523.3; // C note (more audible)
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
    length: i64,
    pos: i64,
    channel_count: i32,
    format: zoto.Format,
    sample_rate: u32,
    allocator: std.mem.Allocator,
    remaining: std.ArrayList(u8),

    const Self = @This();
    const ReadError = error{OutOfMemory};
    const Reader = std.io.Reader(*Self, ReadError, read);

    pub fn reader(self: *Self) Reader {
        return .{ .context = self };
    }

    pub fn read(self: *Self, buf: []u8) ReadError!usize {
        // Handle remaining bytes from previous read
        if (self.remaining.items.len > 0) {
            const n = @min(buf.len, self.remaining.items.len);
            @memcpy(buf[0..n], self.remaining.items[0..n]);

            // Remove copied bytes from remaining
            const new_len = self.remaining.items.len - n;
            std.mem.copyForwards(u8, self.remaining.items[0..new_len], self.remaining.items[n..]);
            self.remaining.shrinkRetainingCapacity(new_len);

            return n;
        }

        if (self.pos == self.length) {
            return 0; // EOF
        }

        var write_buf = buf;
        var orig_buf_len: ?usize = null;
        var eof = false;

        // Check if we'll exceed the length
        if (self.pos + @as(i64, @intCast(buf.len)) > self.length) {
            write_buf = buf[0..@intCast(self.length - self.pos)];
            eof = true;
        }

        // Ensure buffer is aligned to 4-byte boundary
        var aligned_buf: []u8 = undefined;
        var needs_alignment = false;
        if (write_buf.len % 4 > 0) {
            orig_buf_len = write_buf.len;
            const aligned_len = write_buf.len + (4 - write_buf.len % 4);
            aligned_buf = try self.allocator.alloc(u8, aligned_len);
            needs_alignment = true;
        } else {
            aligned_buf = write_buf;
        }
        defer if (needs_alignment) self.allocator.free(aligned_buf);

        const length = @as(f64, @floatFromInt(self.sample_rate)) / self.freq;
        const num = formatByteLength(self.format) * @as(usize, @intCast(self.channel_count));
        var p = @divTrunc(self.pos, @as(i64, @intCast(num)));

        switch (self.format) {
            .float32_le => {
                const samples = aligned_buf.len / num;
                var i: usize = 0;
                while (i < samples) : (i += 1) {
                    const sample = @sin(2.0 * std.math.pi * @as(f64, @floatFromInt(p)) / length) * 0.3;
                    const bits = @as(u32, @bitCast(@as(f32, @floatCast(sample))));

                    var ch: usize = 0;
                    while (ch < self.channel_count) : (ch += 1) {
                        const byte_offset = num * i + 4 * ch;
                        aligned_buf[byte_offset] = @as(u8, @truncate(bits));
                        aligned_buf[byte_offset + 1] = @as(u8, @truncate(bits >> 8));
                        aligned_buf[byte_offset + 2] = @as(u8, @truncate(bits >> 16));
                        aligned_buf[byte_offset + 3] = @as(u8, @truncate(bits >> 24));
                    }
                    p += 1;
                }
            },
            .uint8 => {
                const samples = aligned_buf.len / num;
                var i: usize = 0;
                while (i < samples) : (i += 1) {
                    const max = 127;
                    const sample = @sin(2.0 * std.math.pi * @as(f64, @floatFromInt(p)) / length) * 0.3;
                    const b: u8 = @intFromFloat(sample * max + 128);

                    var ch: usize = 0;
                    while (ch < self.channel_count) : (ch += 1) {
                        aligned_buf[num * i + ch] = b;
                    }
                    p += 1;
                }
            },
            .int16_le => {
                const samples = aligned_buf.len / num;
                var i: usize = 0;
                while (i < samples) : (i += 1) {
                    const max = 32767;
                    const sample = @sin(2.0 * std.math.pi * @as(f64, @floatFromInt(p)) / length) * 0.3;
                    const b: i16 = @intFromFloat(sample * max);

                    var ch: usize = 0;
                    while (ch < self.channel_count) : (ch += 1) {
                        const byte_offset = num * i + 2 * ch;
                        aligned_buf[byte_offset] = @as(u8, @truncate(@as(u16, @bitCast(b))));
                        aligned_buf[byte_offset + 1] = @as(u8, @truncate(@as(u16, @bitCast(b)) >> 8));
                    }
                    p += 1;
                }
            },
        }

        self.pos += @as(i64, @intCast(aligned_buf.len));

        var n = aligned_buf.len;
        if (orig_buf_len) |orig_len| {
            n = @min(orig_len, aligned_buf.len);
            @memcpy(write_buf[0..n], aligned_buf[0..n]);

            // Store remaining bytes
            if (aligned_buf.len > n) {
                try self.remaining.appendSlice(aligned_buf[n..]);
            }
        }

        return n;
    }

    pub fn deinit(self: *Self) void {
        self.remaining.deinit();
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
        .remaining = std.ArrayList(u8).init(allocator),
    };
    return wave;
}
