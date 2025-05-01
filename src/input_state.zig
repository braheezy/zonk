const std = @import("std");
const zglfw = @import("zglfw");

pub const InputState = @This();

current_keys: std.AutoHashMap(zglfw.Key, bool),
previous_keys: std.AutoHashMap(zglfw.Key, bool),

pub fn init(allocator: std.mem.Allocator) !InputState {
    return InputState{
        .current_keys = std.AutoHashMap(zglfw.Key, bool).init(allocator),
        .previous_keys = std.AutoHashMap(zglfw.Key, bool).init(allocator),
    };
}

pub fn deinit(self: *InputState) void {
    self.current_keys.deinit();
    self.previous_keys.deinit();
}

pub fn update(self: *InputState) void {
    self.previous_keys.clearRetainingCapacity();
    var key_iter = self.current_keys.keyIterator();
    while (key_iter.next()) |key| {
        self.previous_keys.put(key.*, self.current_keys.get(key.*).?) catch unreachable;
    }
}

pub fn isKeyPressed(self: *InputState, key: zglfw.Key) bool {
    const current = self.current_keys.get(key) orelse false;
    const previous = self.previous_keys.get(key) orelse false;
    return current and !previous;
}

pub fn isKeyDown(self: *InputState, key: zglfw.Key) bool {
    return self.current_keys.get(key) orelse false;
}

pub fn isKeyReleased(self: *InputState, key: zglfw.Key) bool {
    return !(self.current_keys.get(key) orelse false) and
        (self.previous_keys.get(key) orelse false);
}

pub fn setKeyState(self: *InputState, key: zglfw.Key, is_down: bool) void {
    self.current_keys.put(key, is_down) catch unreachable;
}

pub fn getPressedKeys(self: *InputState, allocator: std.mem.Allocator) ![]zglfw.Key {
    var pressed = std.ArrayList(zglfw.Key).init(allocator);
    var it = self.current_keys.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.*) {
            try pressed.append(entry.key_ptr.*);
        }
    }
    return pressed.toOwnedSlice();
}
