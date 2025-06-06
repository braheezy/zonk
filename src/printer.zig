const std = @import("std");
const Allocator = std.mem.Allocator;
const zgpu = @import("zgpu");
const wgpu = zgpu.wgpu;
const zm = @import("zmath");
const font = @import("font.zig");
const Library = font.Library;

const wgsl_vs =
    \\ struct VertexIn {
    \\     @location(0) position: vec2f,
    \\     @location(1) uv: vec2f,
    \\     @location(2) color: vec4f,
    \\ };
    \\
    \\ struct VertexOut {
    \\     @builtin(position) position: vec4f,
    \\     @location(1) uv: vec2f,
    \\     @location(2) color: vec4f,
    \\ };
    \\
    \\ @vertex fn main(in: VertexIn) -> VertexOut {
    \\     var out: VertexOut;
    \\     out.position = vec4f(in.position, 0.0, 1.0);
    \\     out.uv = in.uv;
    \\     out.color = in.color;
    \\     return out;
    \\ }
;
const wgsl_fs =
    \\ struct VertexOut {
    \\     @builtin(position) position: vec4f,
    \\     @location(1) uv: vec2f,
    \\     @location(2) color: vec4f,
    \\ };
    \\
    \\ @group(0) @binding(0) var t: texture_2d<f32>;
    \\ @group(0) @binding(1) var s: sampler;
    \\
    \\ @fragment fn main(in: VertexOut) -> @location(0) vec4f {
    \\     let tex = textureSample(t, s, in.uv);
    \\     return tex * in.color;
    \\ }
;

const Command = struct {
    position: [2]f32,
    text: []const u8,
    color: [4]f32, // RGBA
};

/// Printer prints text on the screen.
pub const Printer = struct {
    allocator: Allocator,

    font_library: *Library,

    gctx: *zgpu.GraphicsContext,
    pipeline: zgpu.RenderPipelineHandle,
    bind_group: zgpu.BindGroupHandle,
    depth_texture: zgpu.TextureHandle,
    depth_texture_view: zgpu.TextureViewHandle,

    commands: std.ArrayList(Command),

    dpr: u32,

    pub fn init(allocator: Allocator, gctx: *zgpu.GraphicsContext, font_library: *Library, dpr: u32) !Printer {
        const bind_group_layout = gctx.createBindGroupLayout(&.{
            zgpu.textureEntry(0, .{ .fragment = true }, .float, .tvdim_2d, false),
            zgpu.samplerEntry(1, .{ .fragment = true }, .filtering),
        });
        defer gctx.releaseResource(bind_group_layout);

        const pipeline_layout = gctx.createPipelineLayout(&.{bind_group_layout});
        defer gctx.releaseResource(pipeline_layout);

        const vs_module = zgpu.createWgslShaderModule(gctx.device, wgsl_vs, "vs");
        defer vs_module.release();

        const fs_module = zgpu.createWgslShaderModule(gctx.device, wgsl_fs, "fs");
        defer fs_module.release();

        const color_targets = [_]wgpu.ColorTargetState{.{
            .format = zgpu.GraphicsContext.swapchain_format,
            .blend = &.{
                .alpha = .{
                    .operation = .add,
                    .src_factor = .one,
                    .dst_factor = .one_minus_src_alpha,
                },
                .color = .{
                    .operation = .add,
                    .src_factor = .src_alpha,
                    .dst_factor = .one_minus_src_alpha,
                },
            },
        }};

        const vertex_attributes = [_]wgpu.VertexAttribute{
            .{ .format = .float32x2, .offset = 0, .shader_location = 0 },
            .{ .format = .float32x2, .offset = 2 * @sizeOf(f32), .shader_location = 1 },
            .{ .format = .float32x4, .offset = 4 * @sizeOf(f32), .shader_location = 2 },
        };
        const vertex_buffers = [_]wgpu.VertexBufferLayout{.{
            .array_stride = 8 * @sizeOf(f32),
            .attribute_count = vertex_attributes.len,
            .attributes = &vertex_attributes,
        }};

        const pipeline_descriptor = wgpu.RenderPipelineDescriptor{
            .vertex = wgpu.VertexState{
                .module = vs_module,
                .entry_point = "main",
                .buffer_count = vertex_buffers.len,
                .buffers = &vertex_buffers,
            },
            .primitive = wgpu.PrimitiveState{
                .front_face = .ccw,
                .cull_mode = .none,
                .topology = .triangle_list,
            },
            .depth_stencil = &wgpu.DepthStencilState{
                .format = .depth32_float,
                .depth_write_enabled = false,
            },
            .fragment = &wgpu.FragmentState{
                .module = fs_module,
                .entry_point = "main",
                .target_count = color_targets.len,
                .targets = &color_targets,
            },
        };
        const pipeline = gctx.createRenderPipeline(pipeline_layout, pipeline_descriptor);
        const sampler = gctx.createSampler(.{
            .mag_filter = .linear,
            .min_filter = .linear,
            .mipmap_filter = .linear,
            .address_mode_u = .clamp_to_edge,
            .address_mode_v = .clamp_to_edge,
            .address_mode_w = .clamp_to_edge,
            .max_anisotropy = 1,
        });
        const atlas_texture_view = gctx.createTextureView(font_library.atlas_texture.?, .{});

        const bind_group = gctx.createBindGroup(bind_group_layout, &.{
            .{ .binding = 0, .texture_view_handle = atlas_texture_view },
            .{ .binding = 1, .sampler_handle = sampler },
        });

        const depth = createDepthTexture(gctx);

        const commands = try std.ArrayList(Command).initCapacity(allocator, 1024);

        return Printer{
            .gctx = gctx,
            .allocator = allocator,
            .font_library = font_library,

            .pipeline = pipeline,
            .bind_group = bind_group,
            .depth_texture = depth.texture,
            .depth_texture_view = depth.view,

            .commands = commands,

            .dpr = dpr,
        };
    }

    pub fn text(self: *Printer, value: []const u8, x: f32, y: f32, color: [4]f32) !void {
        try self.commands.append(.{
            .position = .{ x, y },
            .text = try self.allocator.dupe(u8, value),
            .color = color,
        });
    }

    pub fn draw(
        self: *Printer,
        back_buffer_view: zgpu.wgpu.TextureView,
        encoder: zgpu.wgpu.CommandEncoder,
    ) !void {
        const atlas_size: f32 = @floatFromInt(self.font_library.atlas_size);
        const screen_width: f32 = @floatFromInt(self.gctx.swapchain_descriptor.width);
        const screen_height: f32 = @floatFromInt(self.gctx.swapchain_descriptor.height);

        var glyph_count: u32 = 0;
        for (self.commands.items) |cmd| {
            glyph_count += @intCast(cmd.text.len);
        }

        // TODO: store previous buffer and detect if it is still valid and only render if not.
        const vertex_buffer = self.gctx.createBuffer(.{
            .usage = .{ .copy_dst = true, .vertex = true },
            .size = glyph_count * 2 * 12 * @sizeOf(f32) * 2, // *2 for color
        });
        defer self.gctx.releaseResource(vertex_buffer);

        const vertex_data = try self.allocator.alloc(f32, glyph_count * 2 * 12 * 2); // *2 for color
        defer self.allocator.free(vertex_data);

        var i: u32 = 0;
        for (self.commands.items) |cmd| {
            const value = cmd;
            const glyphs = try font.shape(
                self.allocator,
                self.font_library.fonts,
                value.text,
                300,
            );
            defer self.allocator.free(glyphs);

            for (glyphs) |info| {
                const p_x: f32 = @floatFromInt(info.glyph.x);
                const p_y: f32 = @floatFromInt(info.glyph.y);
                const s_x: f32 = @floatFromInt(info.glyph.width);
                const s_y: f32 = @floatFromInt(info.glyph.height);

                const x = (value.position[0] * @as(f32, @floatFromInt(self.dpr)) + @as(f32, @floatFromInt(info.x))) / screen_width * 2 - 1;
                const y = -((value.position[1] * @as(f32, @floatFromInt(self.dpr)) + @as(f32, @floatFromInt(info.y))) / screen_height * 2 - 1);
                const w: f32 = s_x / screen_width * 2;
                const h: f32 = s_y / screen_height * 2;

                const color = value.color;

                // 0
                vertex_data[i + 0] = x;
                vertex_data[i + 1] = y - h;
                vertex_data[i + 2] = p_x / atlas_size;
                vertex_data[i + 3] = (p_y + s_y) / atlas_size;
                vertex_data[i + 4] = color[0];
                vertex_data[i + 5] = color[1];
                vertex_data[i + 6] = color[2];
                vertex_data[i + 7] = color[3];

                // 1
                vertex_data[i + 8] = x + w;
                vertex_data[i + 9] = y - h;
                vertex_data[i + 10] = (p_x + s_x) / atlas_size;
                vertex_data[i + 11] = (p_y + s_y) / atlas_size;
                vertex_data[i + 12] = color[0];
                vertex_data[i + 13] = color[1];
                vertex_data[i + 14] = color[2];
                vertex_data[i + 15] = color[3];

                // 2
                vertex_data[i + 16] = x;
                vertex_data[i + 17] = y;
                vertex_data[i + 18] = p_x / atlas_size;
                vertex_data[i + 19] = p_y / atlas_size;
                vertex_data[i + 20] = color[0];
                vertex_data[i + 21] = color[1];
                vertex_data[i + 22] = color[2];
                vertex_data[i + 23] = color[3];

                // 3
                vertex_data[i + 24] = x + w;
                vertex_data[i + 25] = y - h;
                vertex_data[i + 26] = (p_x + s_x) / atlas_size;
                vertex_data[i + 27] = (p_y + s_y) / atlas_size;
                vertex_data[i + 28] = color[0];
                vertex_data[i + 29] = color[1];
                vertex_data[i + 30] = color[2];
                vertex_data[i + 31] = color[3];

                // 4
                vertex_data[i + 32] = x + w;
                vertex_data[i + 33] = y;
                vertex_data[i + 34] = (p_x + s_x) / atlas_size;
                vertex_data[i + 35] = p_y / atlas_size;
                vertex_data[i + 36] = color[0];
                vertex_data[i + 37] = color[1];
                vertex_data[i + 38] = color[2];
                vertex_data[i + 39] = color[3];

                // 5
                vertex_data[i + 40] = x;
                vertex_data[i + 41] = y;
                vertex_data[i + 42] = p_x / atlas_size;
                vertex_data[i + 43] = p_y / atlas_size;
                vertex_data[i + 44] = color[0];
                vertex_data[i + 45] = color[1];
                vertex_data[i + 46] = color[2];
                vertex_data[i + 47] = color[3];

                i += 48;
            }
        }

        self.gctx.queue.writeBuffer(self.gctx.lookupResource(vertex_buffer).?, 0, f32, vertex_data[0..]);

        const vb_info = self.gctx.lookupResourceInfo(vertex_buffer) orelse return;
        const pipeline = self.gctx.lookupResource(self.pipeline) orelse return;
        const bind_group = self.gctx.lookupResource(self.bind_group) orelse return;
        const depth_view = self.gctx.lookupResource(self.depth_texture_view) orelse return;

        const color_attachments = [_]wgpu.RenderPassColorAttachment{.{
            .view = back_buffer_view,
            .load_op = .load,
            .store_op = .store,
        }};
        const depth_attachment = wgpu.RenderPassDepthStencilAttachment{
            .view = depth_view,
            .depth_load_op = .clear,
            .depth_store_op = .store,
            .depth_clear_value = 1.0,
        };
        const render_pass_info = wgpu.RenderPassDescriptor{
            .color_attachment_count = color_attachments.len,
            .color_attachments = &color_attachments,
            .depth_stencil_attachment = &depth_attachment,
        };
        const pass = encoder.beginRenderPass(render_pass_info);
        defer {
            pass.end();
            pass.release();
        }

        pass.setVertexBuffer(0, vb_info.gpuobj.?, 0, vb_info.size);
        pass.setPipeline(pipeline);
        pass.setBindGroup(0, bind_group, &.{});
        pass.draw(glyph_count * 6, 1, 0, 0);

        for (self.commands.items) |cmd| {
            self.allocator.free(cmd.text);
        }
        self.commands.clearRetainingCapacity();
    }

    pub fn deinit(self: *Printer) void {
        self.commands.deinit();
        self.gctx.releaseResource(self.bind_group);
        self.gctx.releaseResource(self.pipeline);
        self.gctx.releaseResource(self.depth_texture);
        self.gctx.releaseResource(self.depth_texture_view);
    }
};

pub fn createDepthTexture(gctx: *zgpu.GraphicsContext) struct {
    texture: zgpu.TextureHandle,
    view: zgpu.TextureViewHandle,
} {
    const texture = gctx.createTexture(.{
        .usage = .{ .render_attachment = true },
        .dimension = .tdim_2d,
        .size = .{
            .width = gctx.swapchain_descriptor.width,
            .height = gctx.swapchain_descriptor.height,
            .depth_or_array_layers = 1,
        },
        .format = .depth32_float,
        .mip_level_count = 1,
        .sample_count = 1,
    });
    const view = gctx.createTextureView(texture, .{});
    return .{ .texture = texture, .view = view };
}
