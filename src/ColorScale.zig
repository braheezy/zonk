pub const ColorScale = @This();

r: f32 = 1.0,
g: f32 = 1.0,
b: f32 = 1.0,
a: f32 = 1.0,

pub fn scale(self: *ColorScale, r: f32, g: f32, b: f32, a: f32) void {
    self.r *= r;
    self.g *= g;
    self.b *= b;
    self.a *= a;
}

pub fn scaleAlpha(self: *ColorScale, a: f32) void {
    self.a *= a;
}
