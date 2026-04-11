const std = @import("std");
const zgpu_build = @import("zgpu");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zonk_mod = b.addModule("zonk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zonk_mod.link_libc = true;

    // zglfw
    const zglfw = b.dependency("zglfw", .{});
    zonk_mod.addImport("zglfw", zglfw.module("root"));

    // zgpu
    const zgpu = b.dependency("zgpu", .{ .webgpu_backend = .wgpu });
    const zgpu_mod = zgpu.module("root");
    zonk_mod.addImport("zgpu", zgpu_mod);

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

    // zigimg
    const zigimg = b.dependency("zigimg", .{}).module("zigimg");
    zonk_mod.addImport("zigimg", zigimg);

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
        // zonk_mod.linkLibrary(zgpu.artifact("zdawn"));
    }

    const zoto_dep = b.dependency("zoto", .{});
    const zoto_mod = zoto_dep.module("zoto");
    const zigaudio_mod = b.dependency("zigaudio", .{}).module("zigaudio");
    // const zstroke_dep = b.dependency("zstroke", .{
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const zstroke_mod = zstroke_dep.module("zstroke");

    const macos_dep = b.dependency("macos", .{});
    zoto_mod.linkLibrary(macos_dep.artifact("macos"));

    buildAnimation(b, target, optimize, zonk_mod, zigimg);
    buildPong(b, target, optimize, zonk_mod, zigimg);
    // buildStroke(b, target, optimize, zonk_mod, zgpu_mod, zstroke_mod);
    // buildSine(b, target, optimize, zoto_mod);
    buildQoaplay(b, target, optimize, zoto_mod, zigaudio_mod);
    // buildTests(b, zonk_mod);
    buildBlur(b, target, optimize, zonk_mod);
}

fn buildPong(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zonk_mod: *std.Build.Module,
    zigimg: *std.Build.Module,
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

    pong_mod.addImport("zonk", zonk_mod);
    pong_mod.addImport("zigimg", zigimg);
}

fn buildAnimation(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zonk_mod: *std.Build.Module,
    zigimg: *std.Build.Module,
) void {
    const animation_mod = b.createModule(.{
        .root_source_file = b.path("examples/animation/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    animation_mod.addImport("zonk", zonk_mod);
    animation_mod.addImport("zigimg", zigimg);

    const animation_exe = b.addExecutable(.{
        .root_module = animation_mod,
        .name = "animation",
    });
    b.installArtifact(animation_exe);
    const run_animation = b.addRunArtifact(animation_exe);
    const run_animation_step = b.step("animation", "Run the animation example");
    run_animation_step.dependOn(&run_animation.step);
}

fn buildSine(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zoto_mod: *std.Build.Module,
) void {
    const sine_mod = b.createModule(.{
        .root_source_file = b.path("examples/sine/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sine_exe = b.addExecutable(.{
        .root_module = sine_mod,
        .name = "sine",
    });

    sine_mod.addImport("zoto", zoto_mod);

    b.installArtifact(sine_exe);
    const run_sineplay = b.addRunArtifact(sine_exe);
    const run_sineplay_step = b.step("sine", "Run the sine audio example");
    run_sineplay_step.dependOn(&run_sineplay.step);
}

fn buildQoaplay(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zoto_mod: *std.Build.Module,
    zigaudio_mod: *std.Build.Module,
) void {
    const qoaplay_mod = b.createModule(.{
        .root_source_file = b.path("examples/qoaplay/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    qoaplay_mod.addImport("zoto", zoto_mod);
    qoaplay_mod.addImport("zigaudio", zigaudio_mod);
    const qoaplay_exe = b.addExecutable(.{
        .root_module = qoaplay_mod,
        .name = "qoaplay",
    });
    b.installArtifact(qoaplay_exe);
    const run_qoaplay = b.addRunArtifact(qoaplay_exe);
    const run_qoaplay_step = b.step("qoaplay", "Run the qoaplay example");
    run_qoaplay_step.dependOn(&run_qoaplay.step);
}

fn buildStroke(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zonk_mod: *std.Build.Module,
    zgpu_mod: *std.Build.Module,
    zstroke_mod: *std.Build.Module,
) void {
    const stroke_mod = b.createModule(.{
        .root_source_file = b.path("examples/stroke/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    stroke_mod.addImport("zonk", zonk_mod);
    stroke_mod.addImport("zgpu", zgpu_mod);
    stroke_mod.addImport("zstroke", zstroke_mod);

    const stroke_exe = b.addExecutable(.{
        .root_module = stroke_mod,
        .name = "stroke",
    });
    b.installArtifact(stroke_exe);

    const run_stroke = b.addRunArtifact(stroke_exe);
    const run_stroke_step = b.step("stroke", "Run the stroke example");
    run_stroke_step.dependOn(&run_stroke.step);
}

fn buildTests(b: *std.Build, zonk_mod: *std.Build.Module) void {
    const zonk_tests = b.addTest(.{
        .root_module = zonk_mod,
    });
    const stroke_tests_mod = b.createModule(.{
        .root_source_file = b.path("examples/stroke/StrokeDemo.zig"),
    });
    stroke_tests_mod.addImport("zonk", zonk_mod);
    stroke_tests_mod.addImport("zgpu", b.dependency("zgpu", .{ .webgpu_backend = .wgpu }).module("root"));
    stroke_tests_mod.addImport("zstroke", b.dependency("zstroke", .{}).module("zstroke"));
    const stroke_tests = b.addTest(.{
        .root_module = stroke_tests_mod,
    });

    const test_step = b.step("test", "Build zonk tests");
    test_step.dependOn(&zonk_tests.step);
    test_step.dependOn(&stroke_tests.step);
}

fn buildBlur(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    zonk_mod: *std.Build.Module,
) void {
    const blur_mod = b.createModule(.{
        .root_source_file = b.path("examples/blur/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    blur_mod.addImport("zonk", zonk_mod);
    const blur_exe = b.addExecutable(.{
        .root_module = blur_mod,
        .name = "blur",
    });
    b.installArtifact(blur_exe);
    const run_blur = b.addRunArtifact(blur_exe);
    const run_blur_step = b.step("blur", "Run the blur example");
    run_blur_step.dependOn(&run_blur.step);
}
