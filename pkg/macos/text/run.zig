const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const graphics = @import("../graphics.zig");
const text = @import("../text.zig");
const c = @import("c.zig").c;

pub const Run = opaque {
    pub fn release(self: *Run) void {
        foundation.CFRelease(self);
    }

    pub fn getGlyphCount(self: *Run) usize {
        return @intCast(c.CTRunGetGlyphCount(@ptrCast(self)));
    }

    pub fn getGlyphsPtr(self: *Run) []const graphics.Glyph {
        const len = self.getGlyphCount();
        if (len == 0) return &.{};
        const ptr = c.CTRunGetGlyphsPtr(@ptrCast(self)) orelse &.{};
        return ptr[0..len];
    }

    pub fn getGlyphs(self: *Run, alloc: Allocator) ![]const graphics.Glyph {
        const len = self.getGlyphCount();
        const ptr = try alloc.alloc(graphics.Glyph, len);
        errdefer alloc.free(ptr);
        c.CTRunGetGlyphs(
            @ptrCast(self),
            .{ .location = 0, .length = 0 },
            @ptrCast(ptr.ptr),
        );
        return ptr;
    }

    pub fn getPositionsPtr(self: *Run) []const graphics.Point {
        const len = self.getGlyphCount();
        if (len == 0) return &.{};
        const ptr = c.CTRunGetPositionsPtr(@ptrCast(self)) orelse &.{};
        return ptr[0..len];
    }

    pub fn getPositions(self: *Run, alloc: Allocator) ![]const graphics.Point {
        const len = self.getGlyphCount();
        const ptr = try alloc.alloc(graphics.Point, len);
        errdefer alloc.free(ptr);
        c.CTRunGetPositions(
            @ptrCast(self),
            .{ .location = 0, .length = 0 },
            @ptrCast(ptr.ptr),
        );
        return ptr;
    }

    pub fn getAdvancesPtr(self: *Run) []const graphics.Size {
        const len = self.getGlyphCount();
        if (len == 0) return &.{};
        const ptr = c.CTRunGetAdvancesPtr(@ptrCast(self)) orelse &.{};
        return ptr[0..len];
    }

    pub fn getAdvances(self: *Run, alloc: Allocator) ![]const graphics.Size {
        const len = self.getGlyphCount();
        const ptr = try alloc.alloc(graphics.Size, len);
        errdefer alloc.free(ptr);
        c.CTRunGetAdvances(
            @ptrCast(self),
            .{ .location = 0, .length = 0 },
            @ptrCast(ptr.ptr),
        );
        return ptr;
    }

    pub fn getStringIndicesPtr(self: *Run) []const usize {
        const len = self.getGlyphCount();
        if (len == 0) return &.{};
        const ptr = c.CTRunGetStringIndicesPtr(@ptrCast(self)) orelse &.{};
        return ptr[0..len];
    }

    pub fn getStringIndices(self: *Run, alloc: Allocator) ![]const usize {
        const len = self.getGlyphCount();
        const ptr = try alloc.alloc(usize, len);
        errdefer alloc.free(ptr);
        c.CTRunGetStringIndices(
            @ptrCast(self),
            .{ .location = 0, .length = 0 },
            @ptrCast(ptr.ptr),
        );
        return ptr;
    }
};
