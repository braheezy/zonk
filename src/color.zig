pub const RGBA = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
};

pub const Color = union(enum) {
    rgba: RGBA,

    pub fn toRGBA(self: Color) RGBA {
        return switch (self) {
            .rgba => |rgba| rgba,
        };
    }
};
