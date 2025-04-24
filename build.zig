const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zonk_mod = b.addModule("zonk", .{
        .root_source_file = b.path("src/App.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zglfw = b.dependency("zglfw", .{});
    zonk_mod.addImport("zglfw", zglfw.module("root"));

    const zgpu = b.dependency("zgpu", .{});
    zonk_mod.addImport("zgpu", zgpu.module("root"));

    const zmath = b.dependency("zmath", .{});
    zonk_mod.addImport("zmath", zmath.module("root"));

    const obj_mod = b.dependency("obj", .{ .target = target, .optimize = optimize });
    zonk_mod.addImport("obj", obj_mod.module("obj"));

    const zpix = b.dependency("zpix", .{});
    zonk_mod.addImport("jpeg", zpix.module("jpeg"));
    zonk_mod.addImport("png", zpix.module("png"));
    zonk_mod.addImport("image", zpix.module("image"));

    if (target.result.os.tag != .emscripten) {
        zonk_mod.linkLibrary(zglfw.artifact("glfw"));
        zonk_mod.linkLibrary(zgpu.artifact("zdawn"));
    }

    buildPong(b, target, optimize, zonk_mod);
}

fn buildPong(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zonk_mod: *std.Build.Module,
) void {
    const pong_mod = b.createModule(.{
        .root_source_file = b.path("examples/pong/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const pong_exe = b.addExecutable(.{
        .root_module = pong_mod,
        .name = "pong",
    });
    b.installArtifact(pong_exe);
    const run_pong = b.addRunArtifact(pong_exe);
    const run_pong_step = b.step("pong", "Run the pong example");
    run_pong_step.dependOn(&run_pong.step);

    @import("zgpu").addLibraryPathsTo(pong_exe);
    pong_exe.root_module.addImport("zonk", zonk_mod);
}
