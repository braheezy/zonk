const objc = @import("objc");
const std = @import("std");
const Mux = @import("mux.zig").Mux;
const Format = @import("mux.zig").Format;

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
    reserved: u32,
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

fn newAudioQueue(sample_rate: u32, channel_count: u32, one_buffer_size_in_bytes: u32) !struct { AudioQueueRef, []AudioQueueBufferRef } {
    const description = AudioStreamBasicDescription{
        .sample_rate = @intCast(sample_rate),
        .format_id = audio_format_linear_pcm,
        .format_flags = audio_format_flag_is_float,
        .bytes_per_packet = channel_count * float32_size_in_bytes,
        .frames_per_packet = 1,
        .bytes_per_frame = channel_count * float32_size_in_bytes,
        .channels_per_frame = channel_count,
        .bits_per_channel = 8 * float32_size_in_bytes,
    };

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
        return error.AudioQueueNewOutputFailed;
    }

    var bufs: [buffer_count]AudioQueueBufferRef = undefined;
    var i: usize = 0;
    while (i < buffer_count) : (i += 1) {
        var buf: AudioQueueBufferRef = undefined;
        const osstatus = AudioQueueAllocateBuffer(audio_queue, one_buffer_size_in_bytes, &buf);
        if (osstatus != no_err) {
            return error.AudioQueueAllocateBufferFailed;
        }
        // Set mAudioDataByteSize to one_buffer_size_in_bytes
        // This requires casting the buffer pointer to *AudioQueueBuffer and setting the field
        // const buf_ptr = @ptrCast(*AudioQueueBuffer, @intToPtr(*anyopaque, buf));
        // buf_ptr.audio_data_byte_size = one_buffer_size_in_bytes;
        buf.audio_data_byte_size = @intCast(one_buffer_size_in_bytes);
        bufs[i] = buf;
    }

    return .{ audio_queue, bufs };
}

const Context = struct {
    audio_queue: AudioQueueRef,
    unqueued_buffers: std.ArrayList(AudioQueueBufferRef),
    one_buffer_size_in_bytes: u32,
    mutex: std.Thread.Mutex,
    condition: std.Thread.Condition,
    to_pause: bool,
    to_resume: bool,
    mux: *Mux,
    ready: bool,
    allocator: std.mem.Allocator,

    pub fn waitForReady(self: *Context) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (!self.ready) {
            self.condition.wait(&self.mutex);
        }
    }

    fn suspendPlay(self: *Context) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // TODO: Add error checking when error handling is implemented
        // if (self.err != null) return self.err;

        self.to_pause = true;
        self.to_resume = false;
        self.condition.signal();
    }

    fn resumePlay(self: *Context) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // TODO: Add error checking when error handling is implemented
        // if (self.err != null) return self.err;

        self.to_pause = false;
        self.to_resume = true;
        self.condition.signal();
    }
};

var context: *Context = undefined;

fn newContext(allocator: std.mem.Allocator, sample_rate: u32, channel_count: u32, format: Format, buffer_size_in_bytes: u32) !*Context {
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

    const c = try allocator.create(Context);
    c.* = Context{
        .audio_queue = undefined,
        .unqueued_buffers = std.ArrayList(AudioQueueBufferRef).init(allocator),
        .mutex = .{},
        .condition = .{},
        .to_pause = false,
        .to_resume = false,
        .one_buffer_size_in_bytes = one_buffer_size_in_bytes,
        .mux = try Mux.init(allocator, sample_rate, channel_count, format),
        .ready = false,
        .allocator = allocator,
    };

    context = c;

    // Spawn the audio worker thread
    const thread = try std.Thread.spawn(.{}, audioContextWorker, .{ c, sample_rate, channel_count });
    thread.detach();

    return c;
}

fn audioContextWorker(ctx: *Context, sample_rate: u32, channel_count: u32) void {
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

    // Call newAudioQueue equivalent
    const queue_result = newAudioQueue(sample_rate, channel_count, ctx.one_buffer_size_in_bytes) catch |err| {
        // Store error in context (equivalent to c.err.TryStore(err))
        std.log.err("newAudioQueue failed: {}", .{err});
        return;
    };

    ctx.audio_queue = queue_result[0];
    // Convert array to ArrayList and populate it
    for (queue_result[1]) |buf| {
        ctx.unqueued_buffers.append(buf) catch |err| {
            std.log.err("Failed to initialize buffer list: {}", .{err});
            return;
        };
    }

    // Call setNotificationHandler equivalent
    setNotificationHandler() catch |err| {
        std.log.err("setNotificationHandler failed: {}", .{err});
        return;
    };

    var retry_count: i32 = 0;
    while (true) {
        const osstatus = AudioQueueStart(ctx.audio_queue, null);
        if (osstatus == no_err) {
            break;
        }

        if (osstatus == av_audio_session_error_code_cannot_start_playing and retry_count < 100) {
            // TODO: use sleepTime() after investigating when this error happens.
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

    // Call loop equivalent (placeholder - function not ported)
    // ctx.loop();
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

fn setNotificationHandler() !void {
    // Get required classes
    const NSObject = objc.getClass("NSObject") orelse return error.NSObjectNotFound;
    const NSWorkspace = objc.getClass("NSWorkspace") orelse return error.NSWorkspaceNotFound;
    const NSString = objc.getClass("NSString") orelse return error.NSStringNotFound;

    // Create notification name strings
    const sleepNotificationName = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"NSWorkspaceWillSleepNotification"});
    const wakeNotificationName = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{"NSWorkspaceDidWakeNotification"});

    // Get shared workspace and notification center
    const sharedWorkspace = NSWorkspace.msgSend(objc.Object, "sharedWorkspace", .{});
    const notificationCenter = sharedWorkspace.msgSend(objc.Object, "notificationCenter", .{});

    // Create observer object (using NSObject as base for simplicity)
    const observer = NSObject.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});

    // Register for sleep notification
    // Note: This is a simplified approach. Full implementation would require proper method registration
    _ = notificationCenter.msgSend(objc.Object, "addObserver:selector:name:object:", .{
        observer,
        @intFromPtr(&setGlobalPause),
        sleepNotificationName,
        @as(objc.Object, @enumFromInt(0)),
    });

    // Register for wake notification
    _ = notificationCenter.msgSend(objc.Object, "addObserver:selector:name:object:", .{
        observer,
        @intFromPtr(&setGlobalResume),
        wakeNotificationName,
        @as(objc.Object, @enumFromInt(0)),
    });
}

fn render(user_data: ?*anyopaque, aq: AudioQueueRef, buffer: AudioQueueBufferRef) callconv(.C) void {
    _ = user_data;
    _ = aq;

    context.mutex.lock();
    defer context.mutex.unlock();

    // Add the finished buffer back to the pool of available buffers
    context.unqueued_buffers.append(buffer) catch |err| {
        std.log.err("Failed to append buffer in render callback: {}", .{err});
        return;
    };

    // Signal that a buffer is available
    context.condition.signal();
}
