pub const c = @import("dispatch/c.zig").c;
pub const data = @import("dispatch/data.zig");
pub const queue = @import("dispatch/queue.zig");
pub const Data = data.Data;

test {
    @import("std").testing.refAllDecls(@This());
}
