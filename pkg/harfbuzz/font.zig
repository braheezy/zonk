const std = @import("std");
const c = @import("c.zig").c;
const Face = @import("face.zig").Face;
const Error = @import("errors.zig").Error;
const Buffer = @import("buffer.zig").Buffer;
const Feature = @import("common.zig").Feature;
pub const Font = struct {
    handle: *c.hb_font_t,

    /// Constructs a new font object from the specified face.
    pub fn create(face: Face) Error!Font {
        const handle = c.hb_font_create(face.handle) orelse return Error.HarfbuzzFailed;
        return Font{ .handle = handle };
    }

    /// Decreases the reference count on the given font object. When the
    /// reference count reaches zero, the font is destroyed, freeing all memory.
    pub fn destroy(self: *Font) void {
        c.hb_font_destroy(self.handle);
    }

    pub fn setScale(self: *Font, x: u32, y: u32) void {
        c.hb_font_set_scale(
            self.handle,
            @intCast(x),
            @intCast(y),
        );
    }
    pub fn shape(self: Font, buf: Buffer, features: ?[]const Feature) void {
        c.hb_shape(
            @ptrCast(self.handle),
            buf.handle,
            if (features) |f| @ptrCast(f.ptr) else null,
            if (features) |f| @intCast(f.len) else 0,
        );
    }
};
