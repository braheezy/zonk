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
    const decoder = result.decoder;
    defer allocator.free(result.samples);

    std.debug.print("sample_count: {d}\n", .{decoder.sample_count});
    std.debug.print("channels: {d}\n", .{decoder.channels});
    std.debug.print("samplerate: {d}\n", .{decoder.sample_rate});

    zoto.printOSVersion();
    // zoto.playAudio("kameks-theme.flac");

    const options = zoto.ContextOptions{
        .sample_rate = 48000,
        .channel_count = 2,
        .format = .int16_le,
    };

    const context = try zoto.newContext(allocator, options);
    defer context.deinit();
    const player = try play(allocator, context, 523.3, 3 * std.time.ns_per_s, options.channel_count, options.format, @intCast(options.sample_rate));
    defer player.deinit();
    std.time.sleep(3 * std.time.ns_per_s);

    // options

    // print samples to file
    // const file = try std.fs.cwd().createFile("samples.txt", .{});
    // defer file.close();
    // for (samples) |sample| {
    //     try std.fmt.formatInt(sample, 10, .lower, .{}, file.writer());
    //     try file.writeAll("\n");
    // }
}

fn play(
    allocator: std.mem.Allocator,
    ctx: *zoto.Context,
    freq: f64,
    duration: usize,
    channel_count: usize,
    format: zoto.Format,
    sample_rate: u32,
) !*zoto.Player {
    var wave = newSineWave(
        allocator,
        freq,
        duration,
        channel_count,
        format,
        sample_rate,
    );
    const reader = wave.reader();
    const p = try ctx.newPlayer(reader.any());
    try p.play();
    return p;
}

const SineWave = struct {
    freq: f64,
    length: usize,
    position: usize,
    channel_count: u8,
    format: zoto.Format,
    sample_rate: u32,
    allocator: std.mem.Allocator,
    remaining: std.ArrayList(u8),

    const Self = @This();
    const ReadError = error{};
    const Reader = std.io.Reader(*Self, ReadError, read);

    pub fn reader(self: *Self) Reader {
        return .{ .context = self };
    }

    pub fn read(self: *Self, buf: []u8) ReadError!usize {
        // Handle remaining bytes from previous read
        if (self.remaining.items.len > 0) {
            const n = @min(buf.len, self.remaining.items.len);
            @memcpy(buf[0..n], self.remaining.items[0..n]);
            self.remaining.replaceRange(0, n, &[_]u8{}) catch unreachable;
            return n;
        }

        // Check for EOF
        if (self.position >= self.length) {
            return 0;
        }

        var write_buf = buf;
        var eof = false;

        // Check if we would exceed length
        if (self.position + buf.len > self.length) {
            write_buf = buf[0 .. self.length - self.position];
            eof = true;
        }

        // Handle buffer alignment for formats that need it
        var orig_buf_len: ?usize = null;
        if (write_buf.len % 4 > 0) {
            orig_buf_len = write_buf.len;
            const aligned_size = write_buf.len + (4 - write_buf.len % 4);
            // Use remaining array as temporary buffer for alignment
            self.remaining.resize(aligned_size) catch return 0;
            write_buf = self.remaining.items;
        }

        const length = @as(f64, @floatFromInt(self.sample_rate)) / self.freq;
        const num = formatByteLength(self.format) * @as(usize, self.channel_count);
        var p = self.position / num;

        switch (self.format) {
            .float32_le => {
                var i: usize = 0;
                while (i < write_buf.len / num) : (i += 1) {
                    const sample = @sin(2.0 * std.math.pi * @as(f64, @floatFromInt(p)) / length) * 0.3;
                    const bits = @as(u32, @bitCast(@as(f32, @floatCast(sample))));

                    var ch: usize = 0;
                    while (ch < self.channel_count) : (ch += 1) {
                        write_buf[num * i + 4 * ch] = @as(u8, @truncate(bits));
                        write_buf[num * i + 1 + 4 * ch] = @as(u8, @truncate(bits >> 8));
                        write_buf[num * i + 2 + 4 * ch] = @as(u8, @truncate(bits >> 16));
                        write_buf[num * i + 3 + 4 * ch] = @as(u8, @truncate(bits >> 24));
                    }
                    p += 1;
                }
            },
            .uint8 => {
                var i: usize = 0;
                while (i < write_buf.len / num) : (i += 1) {
                    const max = 127;
                    const sample = @sin(2.0 * std.math.pi * @as(f64, @floatFromInt(p)) / length) * 0.3 * max;
                    const b: u8 = @intFromFloat(sample + 128);

                    var ch: usize = 0;
                    while (ch < self.channel_count) : (ch += 1) {
                        write_buf[num * i + ch] = b;
                    }
                    p += 1;
                }
            },
            .int16_le => {
                var i: usize = 0;
                while (i < write_buf.len / num) : (i += 1) {
                    const max = 32767;
                    const sample = @sin(2.0 * std.math.pi * @as(f64, @floatFromInt(p)) / length) * 0.3 * max;
                    const b: i16 = @intFromFloat(sample);

                    var ch: usize = 0;
                    while (ch < self.channel_count) : (ch += 1) {
                        write_buf[num * i + 2 * ch] = @as(u8, @truncate(@as(u16, @bitCast(b))));
                        write_buf[num * i + 1 + 2 * ch] = @as(u8, @truncate(@as(u16, @bitCast(b)) >> 8));
                    }
                    p += 1;
                }
            },
        }

        self.position += write_buf.len;

        // Handle original buffer size if we had alignment issues
        if (orig_buf_len) |orig_len| {
            @memcpy(buf[0..orig_len], write_buf[0..orig_len]);
            // Store remaining bytes for next read
            if (write_buf.len > orig_len) {
                self.remaining.replaceRange(0, self.remaining.items.len, write_buf[orig_len..]) catch return orig_len;
            }
            return orig_len;
        }

        return write_buf.len;
    }

    pub fn deinit(self: *Self) void {
        self.remaining.deinit();
    }
};

fn formatByteLength(format: zoto.Format) usize {
    return switch (format) {
        .float32_le => 4,
        .uint8 => 1,
        .int16_le => 2,
    };
}

fn newSineWave(allocator: std.mem.Allocator, freq: f64, duration: usize, channel_count: usize, format: zoto.Format, sample_rate: u32) SineWave {
    const l = channel_count * formatByteLength(format) * @as(usize, sample_rate) * duration / std.time.ns_per_s;
    const aligned_l = (l / 4) * 4;
    return SineWave{
        .freq = freq,
        .length = aligned_l,
        .position = 0,
        .channel_count = @intCast(channel_count),
        .format = format,
        .sample_rate = sample_rate,
        .allocator = allocator,
        .remaining = std.ArrayList(u8).init(allocator),
    };
}
