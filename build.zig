const std = @import("std");
const zgpu_build = @import("zgpu");
const zemscripten_build = @import("zemscripten");

pub const WebgpuBackend = zgpu_build.WebgpuBackend;

fn webgpuBackendOption(b: *std.Build) WebgpuBackend {
    return b.option(
        WebgpuBackend,
        "webgpu_backend",
        "Set zgpu WebGPU backend",
    ) orelse .wgpu;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const webgpu_backend = webgpuBackendOption(b);
    const max_buffer_size = b.option(
        u64,
        "max_buffer_size",
        "Required WebGPU max_buffer_size limit requested by Zonk",
    ) orelse 4 * 1024 * 1024;
    const enable_text_rendering = b.option(
        bool,
        "enable_text_rendering",
        "Compile Zonk text rendering support",
    ) orelse false;
    const is_emscripten = target.result.os.tag == .emscripten;

    const zonk_mod = b.addModule("zonk", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const zonk_options = b.addOptions();
    zonk_options.addOption(u64, "max_buffer_size", max_buffer_size);
    zonk_options.addOption(bool, "enable_text_rendering", enable_text_rendering);
    zonk_mod.addOptions("zonk_options", zonk_options);
    zonk_mod.link_libc = true;

    // zglfw
    const zglfw = b.dependency("zglfw", .{});
    zonk_mod.addImport("zglfw", zglfw.module("root"));

    // zgpu
    const zgpu = b.dependency("zgpu", .{
        .target = target,
        .optimize = optimize,
        .webgpu_backend = webgpu_backend,
    });
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
    if (!is_emscripten and enable_text_rendering) {
        const harfbuzz = b.dependency("harfbuzz", .{
            .target = target,
            .optimize = optimize,
        });
        zonk_mod.addImport("harfbuzz", harfbuzz.module("harfbuzz"));
        const harfbuzz_lib = harfbuzz.artifact("harfbuzz");
        zonk_mod.linkLibrary(harfbuzz_lib);
    }

    // freetype
    if (!is_emscripten and enable_text_rendering) {
        const freetype = b.dependency("freetype", .{
            .target = target,
            .optimize = optimize,
            .@"enable-libpng" = true,
        });
        zonk_mod.addImport("freetype", freetype.module("freetype"));
        const freetype_lib = freetype.artifact("freetype");
        zonk_mod.linkLibrary(freetype_lib);
    }

    if (!is_emscripten) {
        zonk_mod.linkLibrary(zglfw.artifact("glfw"));
        // zonk_mod.linkLibrary(zgpu.artifact("zdawn"));
    }

    var zoto_mod: ?*std.Build.Module = null;
    var zigaudio_mod: ?*std.Build.Module = null;
    if (!is_emscripten) {
        const zoto_dep = b.dependency("zoto", .{});
        zoto_mod = zoto_dep.module("zoto");
        zigaudio_mod = b.dependency("zigaudio", .{}).module("zigaudio");
    }
    // const zstroke_dep = b.dependency("zstroke", .{
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const zstroke_mod = zstroke_dep.module("zstroke");

    if (!is_emscripten) {
        const macos_dep = b.dependency("macos", .{});
        zoto_mod.?.linkLibrary(macos_dep.artifact("macos"));
    }

    buildAnimation(b, target, optimize, zonk_mod, zigimg);
    buildPong(b, target, optimize, zonk_mod, zigimg);
    // buildStroke(b, target, optimize, zonk_mod, zgpu_mod, zstroke_mod);
    // buildSine(b, target, optimize, zoto_mod);
    if (!is_emscripten) {
        buildQoaplay(b, target, optimize, zoto_mod.?, zigaudio_mod.?);
    }
    // buildTests(b, zonk_mod);
    buildBlur(b, target, optimize, zonk_mod);
}

fn addWebExample(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    app_main_mod: *std.Build.Module,
    zonk_mod: *std.Build.Module,
    zigimg: ?*std.Build.Module,
) void {
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .emscripten,
    });
    const zemscripten = b.dependency("zemscripten", .{});

    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm_entry.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .link_libc = true,
        .unwind_tables = .none,
        .imports = &.{
            .{ .name = "app_main", .module = app_main_mod },
            .{ .name = "zonk", .module = zonk_mod },
            .{ .name = "zemscripten", .module = zemscripten.module("root") },
        },
    });
    if (zigimg) |mod| wasm_mod.addImport("zigimg", mod);

    const wasm = b.addLibrary(.{
        .name = name,
        .root_module = wasm_mod,
        .linkage = .static,
    });

    var emcc_flags = zemscripten_build.emccDefaultFlags(b.allocator, .{
        .optimize = optimize,
        .fsanitize = false,
    });
    emcc_flags.put("--use-port=emdawnwebgpu", {}) catch unreachable;

    var emcc_settings = zemscripten_build.emccDefaultSettings(b.allocator, .{
        .optimize = optimize,
        .emsdk_allocator = .emmalloc,
    });
    emcc_settings.put("ALLOW_MEMORY_GROWTH", "1") catch unreachable;
    emcc_settings.put("ASYNCIFY", "1") catch unreachable;
    emcc_settings.put("USE_GLFW", "3") catch unreachable;

    const activate_emsdk_step = zemscripten_build.activateEmsdkStep(b);
    const emcc_step = zemscripten_build.emccStep(
        b,
        &.{},
        &.{wasm},
        .{
            .optimize = optimize,
            .flags = emcc_flags,
            .settings = emcc_settings,
            .use_preload_plugins = true,
            .embed_paths = &.{},
            .preload_paths = &.{
                .{
                    .src_path = b.path("examples"),
                    .virtual_path = "examples",
                },
            },
            .shell_file_path = null,
            .js_library_path = null,
            .out_file_name = b.fmt("{s}.html", .{name}),
            .install_dir = .{ .custom = "web" },
        },
    );
    emcc_step.dependOn(activate_emsdk_step);
    b.getInstallStep().dependOn(emcc_step);

    const emrun_step = zemscripten_build.emrunStep(
        b,
        b.graph.path(.install_prefix, b.fmt("web/{s}.html", .{name})),
        &.{},
    );
    emrun_step.dependOn(emcc_step);
    b.step(b.fmt("{s}-web", .{name}), b.fmt("Build and run {s} in the browser", .{name})).dependOn(emrun_step);
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
        .unwind_tables = if (target.result.os.tag == .emscripten) .none else null,
    });
    pong_mod.addImport("zonk", zonk_mod);
    pong_mod.addImport("zigimg", zigimg);
    if (target.result.os.tag == .emscripten) {
        addWebExample(b, optimize, "pong", pong_mod, zonk_mod, zigimg);
        return;
    }

    const pong_exe = b.addExecutable(.{
        .root_module = pong_mod,
        .name = "pong",
    });
    b.installArtifact(pong_exe);
    const run_pong = b.addRunArtifact(pong_exe);
    const run_pong_step = b.step("pong", "Run the pong example");
    run_pong_step.dependOn(&run_pong.step);
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
        .unwind_tables = if (target.result.os.tag == .emscripten) .none else null,
    });
    animation_mod.addImport("zonk", zonk_mod);
    animation_mod.addImport("zigimg", zigimg);
    if (target.result.os.tag == .emscripten) {
        addWebExample(b, optimize, "animation", animation_mod, zonk_mod, zigimg);
        return;
    }

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
    stroke_tests_mod.addImport("zgpu", b.dependency("zgpu", .{ .webgpu_backend = webgpuBackendOption(b) }).module("root"));
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
        .unwind_tables = if (target.result.os.tag == .emscripten) .none else null,
    });
    blur_mod.addImport("zonk", zonk_mod);
    if (target.result.os.tag == .emscripten) {
        addWebExample(b, optimize, "blur", blur_mod, zonk_mod, null);
        return;
    }

    const blur_exe = b.addExecutable(.{
        .root_module = blur_mod,
        .name = "blur",
    });
    b.installArtifact(blur_exe);
    const run_blur = b.addRunArtifact(blur_exe);
    const run_blur_step = b.step("blur", "Run the blur example");
    run_blur_step.dependOn(&run_blur.step);
}
