const std = @import("std");

pub const Geom = @This();
a_1: f32 = 0,
b: f32 = 0,
c: f32 = 0,
d_1: f32 = 0,
tx: f32 = 0,
ty: f32 = 0,

pub fn translate(self: *Geom, tx: f32, ty: f32) void {
    self.tx += tx;
    self.ty += ty;
}
