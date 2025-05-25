const std = @import("std");
const objc = @import("objc");
const process = std.process;
const ChildProcess = std.process.Child;

pub const mux = @import("mux.zig");
pub const Player = mux.Player;
pub const Format = mux.Format;
const ctx = @import("context.zig");
pub const Context = ctx.Context;
pub const ContextOptions = ctx.Options;
pub const newContext = ctx.newContext;

// Add a static variable to hold the audio player reference
var audio_player: ?objc.Object = null;

pub fn macosVersionAtLeast(major: i64, minor: i64, patch: i64) bool {
    // Get the objc class from the runtime
    const NSProcessInfo = objc.getClass("NSProcessInfo").?;

    // Call a class method with no arguments that returns another objc object.
    const info = NSProcessInfo.msgSend(objc.Object, "processInfo", .{});

    // Call an instance method that returns a boolean and takes a single
    // argument.
    return info.msgSend(bool, "isOperatingSystemAtLeastVersion:", .{
        NSOperatingSystemVersion{ .major = major, .minor = minor, .patch = patch },
    });
}

// This extern struct matches the Cocoa headers for layout.
const NSOperatingSystemVersion = extern struct {
    major: i64,
    minor: i64,
    patch: i64,
};

pub fn printOSVersion() void {
    const NSProcessInfo = objc.getClass("NSProcessInfo").?;
    const info = NSProcessInfo.msgSend(objc.Object, "processInfo", .{});

    // Get the operating system version struct
    const version: NSOperatingSystemVersion = info.msgSend(NSOperatingSystemVersion, "operatingSystemVersion", .{});

    std.debug.print("Operating System Version: {d}.{d}.{d}\n", .{ version.major, version.minor, version.patch });
}

pub fn playAudio(path: []const u8) void {
    // Get required classes
    const NSString = objc.getClass("NSString") orelse std.debug.panic("NSString class not found", .{});
    const NSURL = objc.getClass("NSURL") orelse std.debug.panic("NSURL class not found", .{});
    const AVAudioPlayer = objc.getClass("AVAudioPlayer") orelse std.debug.panic("AVAudioPlayer class not found", .{});

    std.debug.print("Attempting to play audio: {s}\n", .{path});

    // Create NSURL from path
    const nsPath = NSString.msgSend(objc.Object, "stringWithUTF8String:", .{path});
    const url = NSURL.msgSend(objc.Object, "fileURLWithPath:", .{nsPath});

    // Create an error pointer for initialization
    var err_ptr: ?objc.Object = null;

    // Create AVAudioPlayer
    const player = AVAudioPlayer
        .msgSend(objc.Object, "alloc", .{})
        .msgSend(objc.Object, "initWithContentsOfURL:error:", .{ url, &err_ptr });

    // Check for initialization errors
    if (err_ptr != null) {
        std.debug.print("Failed to initialize AVAudioPlayer\n", .{});
        return;
    }

    // Prepare to play
    _ = player.msgSend(bool, "prepareToPlay", .{});

    // Play the audio
    const success = player.msgSend(bool, "play", .{});
    if (success) {
        std.debug.print("Playing audio file: {s}\n", .{path});

        // Store player in global variable to prevent deallocation
        audio_player = player;

        // Get duration of the audio file in seconds
        const duration = player.msgSend(f64, "duration", .{});
        std.debug.print("Audio duration: {d} seconds\n", .{duration});

        // Add a little buffer to ensure playback completes
        const sleep_duration = @as(u64, @intFromFloat(duration * 1000 * 1000 * 1000)) + 500 * 1000 * 1000;

        std.debug.print("Sleeping to allow audio playback...\n", .{});
        std.time.sleep(sleep_duration); // Sleep for the duration plus half a second
        std.debug.print("Done playing.\n", .{});
    } else {
        std.debug.print("Failed to play audio\n", .{});
    }
}

const NoopBlock = objc.Block(struct {}, [_]type{}, void);

fn noopCallback(_: *const NoopBlock.Context) callconv(.C) void {
    // nothing
}
