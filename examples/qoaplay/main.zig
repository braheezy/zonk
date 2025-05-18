const std = @import("std");
const qoa = @import("qoa");

pub fn main() !void {
    const data = @embedFile("test.qoa");
    const result = try qoa.decode(data);
    // const samples = result.samples;
    const desc = result.desc;

    std.debug.print("sample_count: {d}\n", .{desc.sample_count});
    std.debug.print("channels: {d}\n", .{desc.channels});
    std.debug.print("samplerate: {d}\n", .{desc.samplerate});
}
