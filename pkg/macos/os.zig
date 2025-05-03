const log = @import("os/log.zig");

pub const c = @import("os/c.zig");
pub const Log = log.Log;
pub const LogType = log.LogType;

test {
    @import("std").testing.refAllDecls(@This());
}
