const display_link = @import("video/display_link.zig");

pub const c = @import("video/c.zig").c;
pub const DisplayLink = display_link.DisplayLink;

test {
    @import("std").testing.refAllDecls(@This());
}
