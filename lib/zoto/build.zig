const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("zoto", .{
        .root_source_file = b.path("root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "zoto",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    lib_mod.addImport("objc", b.dependency("zig_objc", .{
        .target = target,
        .optimize = optimize,
    }).module("objc"));
}
