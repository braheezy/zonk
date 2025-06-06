const std = @import("std");
const RGBAImage = @import("image").RGBAImage;
const Game = @This();
const Image = @import("Image.zig").Image;

vtable: *const VTable,
instance: *anyopaque,

const VTable = struct {
    updateFn: *const fn (*anyopaque) void,
    drawFn: *const fn (*anyopaque, *Image) void,
    layoutFn: *const fn (*anyopaque, usize, usize) LayoutDim,
};

fn castTo(comptime T: type, ptr: *anyopaque) *T {
    return @as(*T, @ptrCast(@alignCast(ptr)));
}

pub fn update(self: *Game) void {
    self.vtable.updateFn(self.instance);
}

pub fn draw(self: *Game, screen: *Image) void {
    self.vtable.drawFn(self.instance, screen);
}

pub const LayoutDim = struct {
    width: usize,
    height: usize,
};

pub fn layout(self: *Game, width: usize, height: usize) LayoutDim {
    return self.vtable.layoutFn(self.instance, width, height);
}

pub fn init(comptime T: type, instance: *T) Game {
    const vtable = comptime VTable{
        .updateFn = struct {
            fn func(ptr: *anyopaque) void {
                const self = Game.castTo(T, ptr);
                return self.update();
            }
        }.func,
        .drawFn = struct {
            fn func(ptr: *anyopaque, screen: *Image) void {
                const self = Game.castTo(T, ptr);
                return self.draw(screen);
            }
        }.func,
        .layoutFn = struct {
            fn func(ptr: *anyopaque, w: usize, h: usize) LayoutDim {
                const self = Game.castTo(T, ptr);
                return self.layout(w, h);
            }
        }.func,
    };
    return .{
        .vtable = &vtable,
        .instance = instance,
    };
}
