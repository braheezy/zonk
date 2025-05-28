const objc = @import("objc");
const std = @import("std");
const mux = @import("mux.zig");
const Mux = mux.Mux;
const Format = mux.Format;
const Player = mux.Player;

const av_audio_session_error_code_cannot_start_playing = 0x21706c61; // '!pla'
const av_audio_session_error_code_cannot_interrupt_others = 0x21696e74; // '!int'
const av_audio_session_error_code_siri_is_recording = 0x73697269; // 'siri'
const audio_format_linear_pcm = 0x6C70636D; // 'lpcm'
const audio_format_flag_is_float = 1 << 0; // 0x1
const float32_size_in_bytes = 4;
const buffer_count = 4;
const no_err = 0;

pub const AudioStreamBasicDescription = extern struct {
    sample_rate: f64,
    format_id: u32,
    format_flags: u32,
    bytes_per_packet: u32,
    frames_per_packet: u32,
    bytes_per_frame: u32,
    channels_per_frame: u32,
    bits_per_channel: u32,
    reserved: u32 = 0,
};

pub const AudioQueueRef = usize;
pub const AudioQueueBufferRef = *AudioQueueBuffer;
pub const AudioTimeStamp = usize;

pub const AudioStreamPacketDescription = extern struct {
    start_offset: i64,
    variable_frames_in_packet: u32,
    data_byte_size: u32,
};

pub const AudioQueueBuffer = extern struct {
    audio_data_bytes_capacity: u32,
    audio_data: usize, // void*
    audio_data_byte_size: u32,
    user_data: usize, // void*
    packet_description_capacity: u32,
    packet_descriptions: ?*AudioStreamPacketDescription,
    packet_description_count: u32,
};

// Callback type for AudioQueue
pub const AudioQueueOutputCallback = fn (
    user_data: ?*anyopaque,
    aq: AudioQueueRef,
    buffer: AudioQueueBufferRef,
) callconv(.C) void;

// Function signatures for AudioQueue APIs (to be called via objc or Zig FFI)
// These are C functions, but you can call them via Zig's extern or via objc if needed
extern "c" fn AudioQueueNewOutput(
    format: *const AudioStreamBasicDescription,
    callback_proc: ?*const anyopaque, // Actually a function pointer
    user_data: ?*anyopaque,
    callback_run_loop: usize,
    callback_run_loop_mode: usize,
    flags: u32,
    aq: *AudioQueueRef,
) i32;

extern "c" fn AudioQueueAllocateBuffer(
    aq: AudioQueueRef,
    buffer_byte_size: u32,
    buffer: *AudioQueueBufferRef,
) i32;

extern "c" fn AudioQueueEnqueueBuffer(
    aq: AudioQueueRef,
    buffer: AudioQueueBufferRef,
    num_packet_descs: u32,
    packet_descs: ?*AudioStreamPacketDescription,
) i32;

extern "c" fn AudioQueueStart(
    aq: AudioQueueRef,
    start_time: ?*AudioTimeStamp,
) i32;

extern "c" fn AudioQueuePause(
    aq: AudioQueueRef,
) i32;

fn newAudioQueue(allocator: std.mem.Allocator, sample_rate: u32, channel_count: u32, one_buffer_size_in_bytes: u32) !struct { AudioQueueRef, []AudioQueueBufferRef } {
    std.debug.print("newAudioQueue: sample_rate={}, channel_count={}, buffer_size={}\n", .{ sample_rate, channel_count, one_buffer_size_in_bytes });

    const description = AudioStreamBasicDescription{
        .sample_rate = @floatFromInt(sample_rate),
        .format_id = audio_format_linear_pcm,
        .format_flags = audio_format_flag_is_float,
        .bytes_per_packet = channel_count * float32_size_in_bytes,
        .frames_per_packet = 1,
        .bytes_per_frame = channel_count * float32_size_in_bytes,
        .channels_per_frame = channel_count,
        .bits_per_channel = 8 * float32_size_in_bytes,
    };

    std.debug.print("AudioStreamBasicDescription: sample_rate={d}, format_id=0x{x}, format_flags=0x{x}, bytes_per_frame={}, channels_per_frame={}\n", .{ description.sample_rate, description.format_id, description.format_flags, description.bytes_per_frame, description.channels_per_frame });

    var audio_queue: AudioQueueRef = undefined;
    const err = AudioQueueNewOutput(
        &description,
        render,
        null,
        0,
        0,
        0,
        &audio_queue,
    );
    if (err != no_err) {
        std.debug.print("AudioQueueNewOutput failed with error: {}\n", .{err});
        return error.AudioQueueNewOutputFailed;
    }
    std.debug.print("AudioQueueNewOutput succeeded, audio_queue={}\n", .{audio_queue});

    const bufs = try allocator.alloc(AudioQueueBufferRef, buffer_count);
    var i: usize = 0;
    while (i < buffer_count) : (i += 1) {
        var buf: AudioQueueBufferRef = undefined;
        const osstatus = AudioQueueAllocateBuffer(audio_queue, one_buffer_size_in_bytes, &buf);
        if (osstatus != no_err) {
            std.debug.print("AudioQueueAllocateBuffer failed for buffer {} with error: {}\n", .{ i, osstatus });
            return error.AudioQueueAllocateBufferFailed;
        }
        // Set mAudioDataByteSize to one_buffer_size_in_bytes
        // This requires casting the buffer pointer to *AudioQueueBuffer and setting the field
        // const buf_ptr = @ptrCast(*AudioQueueBuffer, @intToPtr(*anyopaque, buf));
        // buf_ptr.audio_data_byte_size = one_buffer_size_in_bytes;
        buf.audio_data_byte_size = @intCast(one_buffer_size_in_bytes);
        bufs[i] = buf;
        std.debug.print("Allocated buffer {}: capacity={}, data_ptr=0x{x}\n", .{ i, buf.audio_data_bytes_capacity, buf.audio_data });
    }

    std.debug.print("newAudioQueue: successfully created {} buffers\n", .{buffer_count});
    return .{ audio_queue, bufs };
}

pub const Context = struct {
    audio_queue: AudioQueueRef,
    unqueued_buffers: std.ArrayList(AudioQueueBufferRef),
    allocated_buffers: ?[]AudioQueueBufferRef = null,
    buf32: ?[]f32 = null,
    one_buffer_size_in_bytes: u32,
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    to_pause: bool,
    to_resume: bool,
    mux: *Mux,
    ready: bool,
    allocator: std.mem.Allocator,
    err: ?anyerror = null,

    pub fn init(allocator: std.mem.Allocator, sample_rate: u32, channel_count: u32, format: Format, buffer_size_in_bytes: u32) !*Context {
        std.debug.print("Darwin driver init: sample_rate={}, channel_count={}, format={}, buffer_size={}\n", .{ sample_rate, channel_count, format, buffer_size_in_bytes });

        // defaultOneBufferSizeInBytes is the default buffer size in bytes.
        //
        // 12288 seems necessary at least on iPod touch (7th) and MacBook Pro 2020.
        // With 48000[Hz] stereo, the maximum delay is (12288*4[buffers] / 4 / 2)[samples] / 48000 [Hz] = 100[ms].
        // '4' is float32 size in bytes. '2' is a number of channels for stereo
        const default_one_buffer_size_in_bytes = 12288;

        var one_buffer_size_in_bytes: u32 = 0;
        if (buffer_size_in_bytes != 0) {
            one_buffer_size_in_bytes = buffer_size_in_bytes / buffer_count;
        } else {
            one_buffer_size_in_bytes = default_one_buffer_size_in_bytes;
        }
        const bytes_per_sample = channel_count * float32_size_in_bytes;
        one_buffer_size_in_bytes = one_buffer_size_in_bytes / bytes_per_sample * bytes_per_sample;

        std.debug.print("Darwin driver: using buffer size {} bytes per buffer\n", .{one_buffer_size_in_bytes});

        const c = try allocator.create(Context);
        c.* = Context{
            .audio_queue = undefined,
            .unqueued_buffers = std.ArrayList(AudioQueueBufferRef).init(allocator),
            .mutex = .{},
            .condition = .{},
            .to_pause = false,
            .to_resume = false,
            .one_buffer_size_in_bytes = one_buffer_size_in_bytes,
            .mux = try Mux.init(
                allocator,
                sample_rate,
                @intCast(channel_count),
                format,
            ),
            .ready = false,
            .allocator = allocator,
        };

        context = c;

        std.debug.print("Darwin driver: spawning audio worker thread\n", .{});
        // Spawn the audio worker thread
        const thread = try std.Thread.spawn(.{}, audioContextWorker, .{ c, sample_rate, channel_count });
        thread.detach();

        return c;
    }

    pub fn deinit(self: *Context) void {
        self.mux.deinit();
        self.unqueued_buffers.deinit();
        if (self.allocated_buffers) |buffers| {
            self.allocator.free(buffers);
        }
        if (self.buf32) |buf| {
            self.allocator.free(buf);
        }
        self.allocator.destroy(self);
    }

    pub fn waitForReady(self: *Context) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (!self.ready) {
            self.condition.wait(&self.mutex);
        }
    }

    pub fn pause(self: *Context) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.err) |err| return err;

        self.to_pause = true;
        self.to_resume = false;
        self.condition.signal();
    }

    pub fn play(self: *Context) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.err) |err| return err;

        self.to_pause = false;
        self.to_resume = true;
        self.condition.signal();
    }

    pub fn getErr(self: *Context) ?anyerror {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.err;
    }

    pub fn newPlayer(self: *Context, reader: std.io.AnyReader) !*Player {
        return try self.mux.newPlayer(reader);
    }

    fn wait(self: *Context) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.unqueued_buffers.items.len == 0 and self.err == null and !self.to_pause and !self.to_resume) {
            self.condition.wait(&self.mutex);
        }
        return self.err == null;
    }

    fn loop(self: *Context) void {
        // Allocate the buffer once and store it in the context
        if (self.buf32 == null) {
            self.buf32 = self.allocator.alloc(f32, self.one_buffer_size_in_bytes / 4) catch |loop_err| {
                self.mutex.lock();
                if (self.err == null) self.err = loop_err;
                self.mutex.unlock();
                return;
            };
        }

        const buf32 = self.buf32.?;

        while (true) {
            if (!self.wait()) {
                return;
            }
            self.appendBuffer(buf32);
        }
    }

    fn appendBuffer(self: *Context, buf32: []f32) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.err != null) {
            return;
        }

        if (self.to_pause) {
            std.debug.print("appendBuffer: pausing audio\n", .{});
            self.pauseImpl() catch |pause_err| {
                if (self.err == null) self.err = pause_err;
            };
            self.to_pause = false;
            return;
        }

        if (self.to_resume) {
            std.debug.print("appendBuffer: resuming audio\n", .{});
            self.resumeImpl() catch |resume_err| {
                if (self.err == null) self.err = resume_err;
            };
            self.to_resume = false;
            return;
        }

        if (self.unqueued_buffers.items.len == 0) {
            std.debug.print("appendBuffer: no unqueued buffers available\n", .{});
            return;
        }

        const buf = self.unqueued_buffers.orderedRemove(0);
        std.debug.print("appendBuffer: processing buffer, {} unqueued buffers remaining\n", .{self.unqueued_buffers.items.len});

        // Read audio data from mux
        self.mux.readFloat32s(buf32) catch |read_err| {
            std.debug.print("appendBuffer: mux.readFloat32s failed: {}\n", .{read_err});
            if (self.err == null) self.err = read_err;
            return;
        };

        // Copy float32 data to audio buffer
        const audio_data_ptr: [*]f32 = @ptrFromInt(buf.audio_data);
        const audio_data_slice = audio_data_ptr[0 .. buf.audio_data_byte_size / float32_size_in_bytes];
        @memcpy(audio_data_slice, buf32[0..@min(buf32.len, audio_data_slice.len)]);

        // Check if we have any non-zero audio data
        var has_audio = false;
        for (audio_data_slice[0..@min(10, audio_data_slice.len)]) |sample| {
            if (sample != 0.0) {
                has_audio = true;
                break;
            }
        }
        std.debug.print("appendBuffer: copied {} samples to audio buffer, has_audio={}\n", .{ @min(buf32.len, audio_data_slice.len), has_audio });

        const osstatus = AudioQueueEnqueueBuffer(self.audio_queue, buf, 0, null);
        if (osstatus != no_err) {
            std.debug.print("appendBuffer: AudioQueueEnqueueBuffer failed with error: {}\n", .{osstatus});
            if (self.err == null) self.err = error.AudioQueueEnqueueBufferFailed;
        } else {
            std.debug.print("appendBuffer: successfully enqueued buffer\n", .{});
        }
    }

    fn pauseImpl(self: *Context) !void {
        const osstatus = AudioQueuePause(self.audio_queue);
        if (osstatus != no_err) {
            return error.AudioQueuePauseFailed;
        }
    }

    fn resumeImpl(self: *Context) !void {
        var retry_count: i32 = 0;
        while (true) {
            const osstatus = AudioQueueStart(self.audio_queue, null);
            if (osstatus == no_err) {
                break;
            }

            if ((osstatus == av_audio_session_error_code_cannot_start_playing or
                osstatus == av_audio_session_error_code_cannot_interrupt_others) and
                retry_count < 30)
            {
                // Use exponential backoff for temporary errors
                std.time.sleep(sleepTime(retry_count));
                retry_count += 1;
                continue;
            }

            if (osstatus == av_audio_session_error_code_siri_is_recording) {
                // Siri recording error should be temporary
                std.time.sleep(10 * std.time.ns_per_ms);
                continue;
            }

            return error.AudioQueueStartFailed;
        }
    }

    fn suspendPlay(self: *Context) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.to_pause = true;
        self.to_resume = false;
        self.condition.signal();
    }

    fn resumePlay(self: *Context) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.to_pause = false;
        self.to_resume = true;
        self.condition.signal();
    }
};

var context: *Context = undefined;

fn audioContextWorker(ctx: *Context, sample_rate: u32, channel_count: u32) void {
    std.debug.print("audioContextWorker: starting worker thread\n", .{});

    // Equivalent of runtime.LockOSThread() - in Zig this is handled by the thread itself

    var ready_closed = false;
    defer {
        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        if (!ready_closed) {
            // Signal ready completion (equivalent to close(ready))
            ctx.ready = true;
            ctx.condition.signal();
        }
    }

    std.debug.print("audioContextWorker: calling newAudioQueue\n", .{});
    // Call newAudioQueue equivalent
    const q, const bs = newAudioQueue(
        ctx.allocator,
        sample_rate,
        channel_count,
        ctx.one_buffer_size_in_bytes,
    ) catch |err| {
        // Store error in context (equivalent to c.err.TryStore(err))
        std.log.err("newAudioQueue failed: {any}", .{err});
        return;
    };

    std.debug.print("audioContextWorker: newAudioQueue succeeded, setting up context\n", .{});
    ctx.audio_queue = q;
    ctx.allocated_buffers = bs;
    ctx.unqueued_buffers.clearAndFree();
    ctx.unqueued_buffers.appendSlice(bs) catch |err| {
        std.log.err("Failed to append buffers in audioContextWorker: {any}", .{err});
        return;
    };

    // setNotificationHandler() catch |err| {
    //     std.log.err("setNotificationHandler failed: {any}", .{err});
    //     return;
    // };

    std.debug.print("audioContextWorker: starting AudioQueue\n", .{});
    var retry_count: i32 = 0;
    while (true) {
        const osstatus = AudioQueueStart(ctx.audio_queue, null);
        if (osstatus == no_err) {
            std.debug.print("audioContextWorker: AudioQueueStart succeeded\n", .{});
            break;
        }

        if (osstatus == av_audio_session_error_code_cannot_start_playing and retry_count < 100) {
            // TODO: use sleepTime() after investigating when this error happens.
            std.debug.print("audioContextWorker: AudioQueueStart failed with cannot_start_playing, retrying... (attempt {})\n", .{retry_count + 1});
            std.time.sleep(10 * std.time.ns_per_ms);
            retry_count += 1;
            continue;
        }

        std.log.err("AudioQueueStart failed at newContext: {d}", .{osstatus});
        return;
    }

    ctx.mutex.lock();
    ctx.ready = true;
    ctx.condition.signal();
    ctx.mutex.unlock();
    ready_closed = true;

    std.debug.print("audioContextWorker: context ready, starting main loop\n", .{});
    // Start the main audio processing loop
    ctx.loop();
}

// Placeholder callback functions for sleep/wake notifications
fn setGlobalPause(self: objc.Object, _: objc.SEL, notification: objc.Object) callconv(.C) void {
    _ = self;
    _ = notification;
    context.suspendPlay();
}

fn setGlobalResume(self: objc.Object, _: objc.SEL, notification: objc.Object) callconv(.C) void {
    _ = self;
    _ = notification;
    context.resumePlay();
}

// fn setNotificationHandler() !void {
//     const ZtoNotificationObserver = setup: {
//         const My_Class = objc.allocateClassPair(objc.getClass("NSObject").?, "ZtoNotificationObserver").?;
//         defer objc.registerClassPair(My_Class);
//         try My_Class.addMethod("receiveSleepNote", setGlobalPause);
//         break :setup My_Class;
//     };

//     const NSObject = objc.getClass("NSObject") orelse return error.NSObjectNotFound;
//     const NSWorkspace = objc.getClass("NSWorkspace") orelse return error.NSWorkspaceNotFound;
//     const NSString = objc.getClass("NSString") orelse return error.NSStringNotFound;

//     // Create notification name strings
//     const sleepNotificationName = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"NSWorkspaceWillSleepNotification"});
//     const wakeNotificationName = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"NSWorkspaceDidWakeNotification"});

//     // Get shared workspace and notification center
//     const sharedWorkspace = NSWorkspace.msgSend(objc.Object, "sharedWorkspace", .{});
//     const notificationCenter = sharedWorkspace.msgSend(objc.Object, "notificationCenter", .{});

//     // Create observer object (using NSObject as base for simplicity)
//     const observer = NSObject.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});

//     // Register for sleep notification
//     // Note: This is a simplified approach. Full implementation would require proper method registration
//     _ = notificationCenter.msgSend(objc.Object, "addObserver:selector:name:object:", .{
//         observer,
//         @intFromPtr(&setGlobalPause),
//         sleepNotificationName,
//         @as(objc.Object, @enumFromInt(0)),
//     });

//     // Register for wake notification
//     _ = notificationCenter.msgSend(objc.Object, "addObserver:selector:name:object:", .{
//         observer,
//         @intFromPtr(&setGlobalResume),
//         wakeNotificationName,
//         @as(objc.Object, @enumFromInt(0)),
//     });
// }

fn render(user_data: ?*anyopaque, aq: AudioQueueRef, buffer: AudioQueueBufferRef) callconv(.C) void {
    _ = user_data;
    _ = aq;

    std.debug.print("render: callback called, buffer processed\n", .{});

    context.mutex.lock();
    defer context.mutex.unlock();

    // Add the finished buffer back to the pool of available buffers
    context.unqueued_buffers.append(buffer) catch |err| {
        std.log.err("Failed to append buffer in render callback: {}", .{err});
        return;
    };

    std.debug.print("render: buffer returned to pool, {} unqueued buffers available\n", .{context.unqueued_buffers.items.len});

    // Signal that a buffer is available
    context.condition.signal();
}

fn sleepTime(count: i32) u64 {
    return switch (count) {
        0 => 10 * std.time.ns_per_ms,
        1 => 20 * std.time.ns_per_ms,
        2 => 50 * std.time.ns_per_ms,
        else => 100 * std.time.ns_per_ms,
    };
}
