const std = @import("std");
const Pool = @import("pool.zig").Pool;
const Buffer = @import("buffer.zig").Buffer;

pub const Format = enum {
    float_32_le,
    uint8,
    int16_le,

    pub fn byteLength(self: Format) usize {
        return switch (self) {
            .float_32_le => 4,
            .uint8 => 1,
            .int16_le => 2,
        };
    }
};

pub const Mux = struct {
    sample_rate: u32,
    channel_count: u8,
    format: Format,
    players: std.ArrayList(*Player),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    condition: std.Thread.Condition = .{},

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32, channel_count: u8, format: Format) !*Mux {
        var self = Mux{
            .sample_rate = sample_rate,
            .channel_count = channel_count,
            .format = format,
            .allocator = allocator,
            .players = std.ArrayList(*Player).init(allocator),
        };
        const thread = try std.Thread.spawn(.{}, muxLoop, self);
        thread.detach();
        return &self;
    }

    pub fn newPlayer(self: *Mux, src: std.io.AnyReader) *Player {
        return &Player{
            .mux = self,
            .src = src,
            .previous_volume = 1.0,
            .volume = 1.0,
            .buffer = std.ArrayList(u8).init(self.allocator),
            .buffer_size = self.defaultBufferSize(),
        };
    }

    pub fn addPlayer(self: *Mux, player: Player) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.players.append(player);
        self.condition.signal();
    }

    pub fn readFloat32s(self: *Mux, dst: []f32) !usize {
        self.mutex.lock();

        const players = try self.players.clone();
        self.mutex.unlock();

        @memset(dst, 0);

        for (players) |player| {
            player.readBufferAndAdd(dst);
        }
        self.condition.signal();
    }

    pub fn removePlayer(self: *Mux, player: *Player) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.players.items, 0..) |p, i| {
            if (p == player) {
                self.players.orderedRemove(i);
                break;
            }
        }
        self.condition.signal();
    }

    fn defaultBufferSize(self: *Mux) usize {
        const bytes_per_sample = @as(usize, @intCast(self.channel_count)) * self.format.byteLength();
        const s = self.sample_rate * bytes_per_sample / 2;
        return (s / bytes_per_sample) * bytes_per_sample;
    }

    fn wait(self: *Mux) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Loop until we should proceed
        while (self.shouldWait()) {
            // Atomically release the mutex and block until signaled,
            // then re-acquire before returning
            self.condition.wait(&self.mutex);
        }
    }

    fn shouldWait(self: *Mux) bool {
        for (self.players.items) |player| {
            if (player.canReadSourceToBuffer()) {
                return false;
            }
        }
        return true;
    }
};

fn muxLoop(self: *Mux) !void {
    var players = std.ArrayList(*Player).init(self.allocator);
    while (true) {
        self.wait();

        self.mutex.lock();
        players.clearAndFree();
        players = try self.players.clone();
        self.mutex.unlock();

        var all_zero = true;
        for (players.items) |player| {
            const n = player.readSourceToBuffer();
            if (n != 0) {
                all_zero = false;
            }
        }

        // Sleeping is necessary especially on browsers.
        // Sometimes a player continues to read 0 bytes from the source and this loop can be a busy loop in such case.
        if (all_zero) {
            std.time.sleep(std.time.ns_per_ms);
        }
    }
}

const PlayerState = enum {
    paused,
    play,
    closed,
};

pub const Player = struct {
    mux: *Mux,
    src: std.io.AnyReader,
    previous_volume: f64,
    volume: f64,
    state: PlayerState,
    buffer_pool: ?Pool = null,
    buffer: std.ArrayList(u8),
    eof: bool,
    buffer_size: usize,
    mutex: std.Thread.Mutex = .{},

    pub fn play(self: *Player) void {
        // Start a new thread to run playImpl
        const thread = try std.Thread.spawn(.{}, Player.playThread, self);
        thread.detach();
    }

    pub fn pause(self: *Player) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state != .play) {
            return;
        }
        self.state = .pause;
    }

    pub fn setBufferSize(self: *Player, buffer_size: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const original_size = self.buffer_size;
        self.buffer_size = buffer_size;
        if (buffer_size == 0) {
            self.buffer_size = self.mux.defaultBufferSize();
        }
        if (original_size != self.buffer_size) {
            if (self.buffer_pool) |p| p.deinit();
            self.buffer_pool = null;
        }
    }

    pub fn reset(self: *Player) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.resetImpl();
    }

    pub fn isPlaying(self: *Player) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state == .play;
    }

    pub fn getVolume(self: *Player) f64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.volume;
    }

    pub fn setVolume(self: *Player, volume: f64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.volume = volume;
        if (self.state != .play) {
            self.previous_volume = volume;
        }
    }

    pub fn bufferedSize(self: *Player) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.buffer.len;
    }

    pub fn close(self: *Player) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.closeImpl();
    }

    fn playThread(ctx: *anyopaque) !void {
        var self: *Player = @ptrCast(ctx);
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.playImpl();
    }

    fn playImpl(self: *Player) !void {
        if (self.state != .paused) {
            return;
        }
        self.state = .play;
        if (!self.eof) {
            const buf = self.getTempBuffer();
            defer {
                if (self.buffer_pool) |p| {
                    p.release(buf);
                }
            }
            while (self.buffer.len < self.buffer_size) {
                const bytes_read = try self.read(buf.buf);
                self.buffer.appendSlice(buf.buf[0..bytes_read]);
                if (bytes_read == 0) {
                    self.eof = true;
                    break;
                }
            }
        }
        if (self.eof and self.buffer.len == 0) {
            self.state = .paused;
        }
        self.addToPlayers();
    }

    fn resetImpl(self: *Player) void {
        if (self.state == .closed) {
            return;
        }
        self.state = .paused;
        self.buffer.clearAndFree();
        self.eof = false;
    }

    fn closeImpl(self: *Player) !void {
        self.removeFromPlayers();

        if (self.state == .closed) {
            return error.PlayerAlreadyClosed;
        }
        self.state = .closed;
        self.buffer.clearAndFree();
    }

    fn addToPlayers(self: *Player) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.mux.addPlayer(self);
    }

    fn removeFromPlayers(self: *Player) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.mux.removePlayer(self);
    }

    fn read(self: *Player, buf: []u8) !usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.src.read(buf);
    }

    fn canReadSourceToBuffer(self: *Player) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.eof) {
            return false;
        }

        return self.buffer.len < self.buffer_size;
    }

    fn readBufferAndAdd(self: *Player, dst: []f32) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state != .play) {
            return 0;
        }

        const format = self.mux.format;
        const bit_depth_in_bytes = format.byteLength();
        const n = dst.len / bit_depth_in_bytes;
        if (n > self.buffer.len) {
            n = self.buffer.len;
        }

        const previous_volume: f32 = @floatCast(self.previous_volume);
        const volume: f32 = @floatCast(self.volume);

        const channel_count = self.mux.channel_count;
        const rate_denominator: f32 = @floatCast(n / channel_count);

        const src = self.buffer[0 .. n * bit_depth_in_bytes];
        for (0..n) |i| {
            const v: f32 = switch (format) {
                .float_32_le => @bitCast(src[4 * i] | src[4 * i + 1] << 8 | src[4 * i + 2] << 16 | src[4 * i + 3] << 24),
                .uint8 => blk: {
                    const v8 = src[i];
                    break :blk (v8 - (1 << 7)) / (1 << 7);
                },
                .int16_le => blk: {
                    const v16 = src[2 * i] | src[2 * i + 1] << 8;
                    break :blk v16 / (1 << 15);
                },
            };
            if (volume == previous_volume) {
                dst[i] += v * volume;
            } else {
                const rate = i / channel_count / rate_denominator;
                if (rate > 1) {
                    rate = 1;
                }
                dst[i] += v * (volume * rate + previous_volume * (1 - rate));
            }
        }

        self.previous_volume = volume;
        const copy_size = self.buffer.len - (n * bit_depth_in_bytes);
        @memcpy(self.buffer[0..copy_size], src[n * bit_depth_in_bytes ..]);
        self.buffer = self.buffer[0..copy_size];

        if (self.eof and self.buffer.len == 0) {
            self.state = .paused;
        }

        return n;
    }

    fn readSourceToBuffer(self: *Player) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.state == .closed) {
            return 0;
        }

        if (self.buffer.len >= self.buffer_size) {
            return 0;
        }

        const buf = self.getTempBuffer();
        defer {
            if (self.buffer_pool) |p| {
                p.release(buf);
            }
        }
        const n = try self.read(buf.buf);
        self.buffer.appendSlice(buf.buf[0..n]);
        if (n == 0) {
            self.eof = true;
            if (self.buffer.len == 0) {
                self.state = .paused;
            }
        }
        return n;
    }

    fn getTempBuffer(self: *Player) *Buffer {
        if (self.buffer_pool == null) {
            self.buffer_pool = try Pool.init(self.mux.allocator, self.buffer_size);
        }
        const buffer = try self.buffer_pool.?.acquire();
        return buffer;
    }
};
