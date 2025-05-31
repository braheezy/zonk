const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zonk_mod = b.addModule("zonk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // zglfw
    const zglfw = b.dependency("zglfw", .{});
    zonk_mod.addImport("zglfw", zglfw.module("root"));

    // zgpu
    const zgpu = b.dependency("zgpu", .{});
    zonk_mod.addImport("zgpu", zgpu.module("root"));

    // zmath
    {
        const zmath = b.dependency("zmath", .{});
        zonk_mod.addImport("zmath", zmath.module("root"));
    }

    // obj
    {
        const obj_mod = b.dependency("obj", .{ .target = target, .optimize = optimize });
        zonk_mod.addImport("obj", obj_mod.module("obj"));
    }

    // zpix
    const zpix = b.dependency("zpix", .{});
    {
        zonk_mod.addImport("jpeg", zpix.module("jpeg"));
        zonk_mod.addImport("png", zpix.module("png"));
        const image_mod = zpix.module("image");
        zonk_mod.addImport("image", image_mod);
    }

    // harfbuzz
    {
        const harfbuzz = b.dependency("harfbuzz", .{
            .target = target,
            .optimize = optimize,
        });
        zonk_mod.addImport("harfbuzz", harfbuzz.module("harfbuzz"));
        const harfbuzz_lib = harfbuzz.artifact("harfbuzz");
        zonk_mod.linkLibrary(harfbuzz_lib);
    }

    // freetype
    {
        const freetype = b.dependency("freetype", .{
            .target = target,
            .optimize = optimize,
            .@"enable-libpng" = true,
        });
        zonk_mod.addImport("freetype", freetype.module("freetype"));
        const freetype_lib = freetype.artifact("freetype");
        zonk_mod.linkLibrary(freetype_lib);
    }

    if (target.result.os.tag != .emscripten) {
        zonk_mod.linkLibrary(zglfw.artifact("glfw"));
        zonk_mod.linkLibrary(zgpu.artifact("zdawn"));
    }

    // buildPong(b, target, optimize, zonk_mod, zpix);
    // buildAnimation(b, target, optimize, zonk_mod, zpix);

    const qoa_mod = b.createModule(.{
        .root_source_file = b.path("lib/qoa/qoa.zig"),
        .target = target,
        .optimize = optimize,
    });
    const qoaplay_mod = b.createModule(.{
        .root_source_file = b.path("examples/qoaplay/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    qoaplay_mod.addImport("qoa", qoa_mod);
    const qoaplay_exe = b.addExecutable(.{
        .root_module = qoaplay_mod,
        .name = "qoaplay",
    });
    b.installArtifact(qoaplay_exe);
    const run_qoaplay = b.addRunArtifact(qoaplay_exe);
    const run_qoaplay_step = b.step("qoaplay", "Run the qoaplay example");
    run_qoaplay_step.dependOn(&run_qoaplay.step);

    const zoto_dep = b.dependency("zoto", .{});
    const zoto_mod = zoto_dep.module("zoto");
    qoaplay_mod.addImport("zoto", zoto_mod);

    const macos_dep = b.dependency("macos", .{});
    qoaplay_exe.linkLibrary(macos_dep.artifact("macos"));
}

fn buildPong(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zonk_mod: *std.Build.Module,
    zpix: *std.Build.Dependency,
) void {
    const image_mod = zpix.module("image");
    const color_mod = zpix.module("color");
    const zpix_mod = zpix.module("zpix");

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
    pong_mod.addImport("zonk", zonk_mod);
    pong_mod.addImport("image", image_mod);
    pong_mod.addImport("color", color_mod);
    pong_mod.addImport("zpix", zpix_mod);
}

fn buildAnimation(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zonk_mod: *std.Build.Module,
    zpix: *std.Build.Dependency,
) void {
    const zpix_mod = zpix.module("zpix");

    const animation_mod = b.createModule(.{
        .root_source_file = b.path("examples/animation/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    animation_mod.addImport("zonk", zonk_mod);
    animation_mod.addImport("zpix", zpix_mod);

    const animation_exe = b.addExecutable(.{
        .root_module = animation_mod,
        .name = "animation",
    });
    @import("zgpu").addLibraryPathsTo(animation_exe);
    b.installArtifact(animation_exe);
    const run_animation = b.addRunArtifact(animation_exe);
    const run_animation_step = b.step("animation", "Run the animation example");
    run_animation_step.dependOn(&run_animation.step);
}
