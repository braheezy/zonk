const std = @import("std");

/// Represents a 2D affine transformation matrix:
/// | a  c  tx |
/// | b  d  ty |
/// | 0  0  1  |
pub const Geom = @This();

a: f32 = 1.0, // X scale
b: f32 = 0.0, // X skew
c: f32 = 0.0, // Y skew
d: f32 = 1.0, // Y scale
tx: f32 = 0.0, // X translation
ty: f32 = 0.0, // Y translation

/// Reset to identity matrix
pub fn reset(self: *Geom) void {
    self.a = 1.0;
    self.b = 0.0;
    self.c = 0.0;
    self.d = 1.0;
    self.tx = 0.0;
    self.ty = 0.0;
}

/// Apply translation by concatenating with a translation matrix
pub fn translate(self: *Geom, dx: f32, dy: f32) void {
    // Translation matrix concatenation:
    // [a  c  tx]   [1  0  dx]   [a  c  a*dx + c*dy + tx]
    // [b  d  ty] * [0  1  dy] = [b  d  b*dx + d*dy + ty]
    // [0  0  1 ]   [0  0  1 ]   [0  0  1              ]

    self.tx = self.a * dx + self.c * dy + self.tx;
    self.ty = self.b * dx + self.d * dy + self.ty;
}

/// Apply scaling by concatenating with a scale matrix
pub fn scale(self: *Geom, sx: f32, sy: f32) void {
    // Scale matrix concatenation:
    // [a  c  tx]   [sx 0  0]   [a*sx  c*sy  tx]
    // [b  d  ty] * [0  sy 0] = [b*sx  d*sy  ty]
    // [0  0  1 ]   [0  0  1]   [0     0     1 ]

    self.a *= sx;
    self.b *= sx;
    self.c *= sy;
    self.d *= sy;
}

/// Apply rotation (angle in radians)
pub fn rotate(self: *Geom, angle: f32) void {
    const cos_a = @cos(angle);
    const sin_a = @sin(angle);

    const new_a = self.a * cos_a - self.c * sin_a;
    const new_b = self.b * cos_a - self.d * sin_a;
    const new_c = self.a * sin_a + self.c * cos_a;
    const new_d = self.b * sin_a + self.d * cos_a;

    self.a = new_a;
    self.b = new_b;
    self.c = new_c;
    self.d = new_d;
}

/// Apply a 2D point transformation
pub fn apply(self: *const Geom, x: f32, y: f32) struct { x: f32, y: f32 } {
    return .{
        .x = self.a * x + self.c * y + self.tx,
        .y = self.b * x + self.d * y + self.ty,
    };
}

/// Check if this is an identity transformation
pub fn isIdentity(self: *const Geom) bool {
    return self.a == 1.0 and self.b == 0.0 and self.c == 0.0 and
        self.d == 1.0 and self.tx == 0.0 and self.ty == 0.0;
}

/// Concatenate with another transformation matrix
pub fn concat(self: *Geom, other: *const Geom) void {
    const new_a = self.a * other.a + self.c * other.b;
    const new_b = self.b * other.a + self.d * other.b;
    const new_c = self.a * other.c + self.c * other.d;
    const new_d = self.b * other.c + self.d * other.d;
    const new_tx = self.a * other.tx + self.c * other.ty + self.tx;
    const new_ty = self.b * other.tx + self.d * other.ty + self.ty;

    self.a = new_a;
    self.b = new_b;
    self.c = new_c;
    self.d = new_d;
    self.tx = new_tx;
    self.ty = new_ty;
}
