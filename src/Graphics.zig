const std = @import("std");
const zgpu = @import("zgpu");
const image = @import("image");

const App = @import("App.zig");
const ResourceManager = @import("ResourceManager.zig");

pub const Graphics = @This();

allocator: std.mem.Allocator,
gfx: *zgpu.GraphicsContext,
screen: image.Image = .{ .RGBA = undefined },
screen_texture: zgpu.TextureHandle = undefined,
screen_texture_view: zgpu.TextureViewHandle = undefined,
screen_bind_group: zgpu.BindGroupHandle = undefined,
pipeline: zgpu.RenderPipelineHandle = undefined,
vertex_buffer: zgpu.wgpu.Buffer = undefined,
index_buffer: zgpu.wgpu.Buffer = undefined,

pub const Vertex2D = struct {
    position: [2]f32,
    color: [4]f32,
    uv: [2]f32,
};

pub const DrawOptions = struct {
    color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },
};

pub fn init(
    gfx: *zgpu.GraphicsContext,
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
) !*Graphics {
    const graphics = try allocator.create(Graphics);
    graphics.* = .{
        .allocator = allocator,
        .gfx = gfx,
    };

    // Create an RGBA image for the screen
    graphics.screen = image.Image{ .RGBA = try image.RGBAImage.init(
        allocator,
        .{
            .min = .{
                .x = 0,
                .y = 0,
            },
            .max = .{
                .x = @as(i32, @intCast(width)),
                .y = @as(i32, @intCast(height)),
            },
        },
    ) };

    // Create the screen texture
    graphics.screen_texture = gfx.createTexture(.{
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .size = .{
            .width = width,
            .height = height,
            .depth_or_array_layers = 1,
        },
        .format = .rgba8_unorm,
        .mip_level_count = 1,
    });

    // Create texture view
    graphics.screen_texture_view = gfx.createTextureView(graphics.screen_texture, .{
        .aspect = .all,
        .base_array_layer = 0,
        .array_layer_count = 1,
        .base_mip_level = 0,
        .mip_level_count = 1,
        .dimension = .tvdim_2d,
        .format = .rgba8_unorm,
    });

    // Create sampler
    const sampler = gfx.createSampler(.{
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .mipmap_filter = .nearest,
        .address_mode_u = .clamp_to_edge,
        .address_mode_v = .clamp_to_edge,
        .address_mode_w = .clamp_to_edge,
    });

    // Create bind group layout
    const bind_group_layout = gfx.createBindGroupLayout(&.{
        zgpu.bufferEntry(
            0,
            .{ .vertex = true, .fragment = true },
            .uniform,
            true,
            0,
        ),
        .{
            .binding = 1,
            .visibility = .{ .fragment = true },
            .texture = .{
                .sample_type = .float,
                .view_dimension = .tvdim_2d,
            },
        },
        .{
            .binding = 2,
            .visibility = .{ .fragment = true },
            .sampler = .{
                .binding_type = .filtering,
            },
        },
    });
    defer gfx.releaseResource(bind_group_layout);

    // Create pipeline layout
    const pipeline_layout = gfx.createPipelineLayout(&.{bind_group_layout});
    defer gfx.releaseResource(pipeline_layout);

    // Create vertex and index buffers
    const vertex_buffer_desc = zgpu.wgpu.BufferDescriptor{
        .label = "Vertex buffer",
        .usage = .{ .copy_dst = true, .vertex = true },
        .size = 1024 * @sizeOf(Vertex2D),
        .mapped_at_creation = .false,
    };
    graphics.vertex_buffer = gfx.device.createBuffer(vertex_buffer_desc);

    const index_buffer_desc = zgpu.wgpu.BufferDescriptor{
        .label = "Index buffer",
        .usage = .{ .copy_dst = true, .index = true },
        .size = 1024 * @sizeOf(u16),
        .mapped_at_creation = .false,
    };
    graphics.index_buffer = gfx.device.createBuffer(index_buffer_desc);

    // Create bind group
    graphics.screen_bind_group = gfx.createBindGroup(bind_group_layout, &.{
        .{
            .binding = 0,
            .buffer_handle = graphics.gfx.uniforms.buffer,
            .offset = 0,
            .size = @sizeOf(DrawOptions),
        },
        .{
            .binding = 1,
            .texture_view_handle = graphics.screen_texture_view,
        },
        .{
            .binding = 2,
            .sampler_handle = sampler,
        },
    });

    // Create render pipeline
    const shader_module = try ResourceManager.loadShaderModule(
        allocator,
        "src/shaders/2d.wgsl",
        gfx.device,
    );
    defer shader_module.release();

    const color_targets = [_]zgpu.wgpu.ColorTargetState{.{
        .format = .bgra8_unorm,
        .blend = &zgpu.wgpu.BlendState{
            .color = .{
                .src_factor = .src_alpha,
                .dst_factor = .one_minus_src_alpha,
                .operation = .add,
            },
            .alpha = .{
                .src_factor = .zero,
                .dst_factor = .one,
                .operation = .add,
            },
        },
    }};

    const vertex_attributes = [_]zgpu.wgpu.VertexAttribute{
        .{
            .shader_location = 0,
            .format = .float32x2,
            .offset = @offsetOf(Vertex2D, "position"),
        },
        .{
            .shader_location = 1,
            .format = .float32x4,
            .offset = @offsetOf(Vertex2D, "color"),
        },
        .{
            .shader_location = 2,
            .format = .float32x2,
            .offset = @offsetOf(Vertex2D, "uv"),
        },
    };

    const vertex_buffer_layout = zgpu.wgpu.VertexBufferLayout{
        .array_stride = @sizeOf(Vertex2D),
        .attribute_count = vertex_attributes.len,
        .attributes = &vertex_attributes,
    };

    const pipeline_desc = zgpu.wgpu.RenderPipelineDescriptor{
        .vertex = .{
            .module = shader_module,
            .entry_point = "vs_main",
            .buffer_count = 1,
            .buffers = &[_]zgpu.wgpu.VertexBufferLayout{vertex_buffer_layout},
        },
        .primitive = .{
            .topology = .triangle_list,
            .front_face = .ccw,
            .cull_mode = .none,
        },
        .fragment = &zgpu.wgpu.FragmentState{
            .module = shader_module,
            .entry_point = "fs_main",
            .target_count = color_targets.len,
            .targets = &color_targets,
        },
        .depth_stencil = null,
        .multisample = .{},
    };

    graphics.pipeline = gfx.createRenderPipeline(pipeline_layout, pipeline_desc);

    return graphics;
}

pub fn deinit(self: *Graphics) void {
    self.screen.free(self.allocator);
    self.gfx.releaseResource(self.screen_texture);
    self.gfx.releaseResource(self.screen_texture_view);
    self.gfx.releaseResource(self.screen_bind_group);
    self.gfx.releaseResource(self.pipeline);
    self.vertex_buffer.release();
    self.index_buffer.release();
    self.gfx.destroy(self.allocator);

    self.allocator.destroy(self);
}

pub fn updateScreen(self: *Graphics) void {
    // Get RGBA pixels from the screen image
    const pixels = self.screen.rgbaPixels(self.allocator) catch return;
    defer self.allocator.free(pixels);

    const rect = self.screen.bounds();
    const width = @as(u32, @intCast(rect.dX()));
    const height = @as(u32, @intCast(rect.dY()));

    // Update the texture with the new pixel data
    self.gfx.queue.writeTexture(
        .{ .texture = self.screen_texture },
        .{
            .bytes_per_row = width * 4,
            .rows_per_image = height,
        },
        .{ .width = width, .height = height },
        pixels,
    );
}

pub fn drawRect(self: *Graphics, x: f32, y: f32, width: f32, height: f32, opts: DrawOptions) void {
    const vertices = [_]Vertex2D{
        // Top-left
        .{
            .position = .{ x, y + height },
            .color = opts.color,
            .uv = .{ 0, 1 },
        },
        // Bottom-left
        .{
            .position = .{ x, y },
            .color = opts.color,
            .uv = .{ 0, 0 },
        },
        // Bottom-right
        .{
            .position = .{ x + width, y },
            .color = opts.color,
            .uv = .{ 1, 0 },
        },
        // Top-right
        .{
            .position = .{ x + width, y + height },
            .color = opts.color,
            .uv = .{ 1, 1 },
        },
    };

    const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

    // Upload vertex and index data
    self.gfx.queue.writeBuffer(self.vertex_buffer, 0, Vertex2D, &vertices);
    self.gfx.queue.writeBuffer(self.index_buffer, 0, u16, &indices);

    // Get current texture view
    const view = self.gfx.swapchain.getCurrentTextureView();
    defer view.release();

    // Create command encoder
    const encoder = self.gfx.device.createCommandEncoder(null);
    defer encoder.release();

    // Begin render pass
    const color_attachment = [_]zgpu.wgpu.RenderPassColorAttachment{.{
        .view = view,
        .load_op = .clear,
        .store_op = .store,
        .clear_value = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1.0 },
    }};

    const render_pass_info = zgpu.wgpu.RenderPassDescriptor{
        .color_attachments = &color_attachment,
        .color_attachment_count = 1,
        .depth_stencil_attachment = null,
    };

    const pass = encoder.beginRenderPass(render_pass_info);

    // Set pipeline and bind group
    pass.setPipeline(self.gfx.lookupResource(self.pipeline) orelse unreachable);
    pass.setBindGroup(
        0,
        self.gfx.lookupResource(self.screen_bind_group) orelse unreachable,
        &.{0},
    );

    // Set vertex and index buffers
    pass.setVertexBuffer(0, self.vertex_buffer, 0, vertices.len * @sizeOf(Vertex2D));
    pass.setIndexBuffer(self.index_buffer, .uint16, 0, indices.len * @sizeOf(u16));

    // Draw
    pass.drawIndexed(indices.len, 1, 0, 0, 0);

    zgpu.endReleasePass(pass);

    // Submit command buffer
    const command_buffer = encoder.finish(null);
    defer command_buffer.release();

    self.gfx.submit(&.{command_buffer});
}

pub fn fillRect(self: *Graphics, x: f32, y: f32, width: f32, height: f32, color: [4]f32) void {
    self.drawRect(x, y, width, height, .{ .color = color });
}

// pub fn drawImage(self: *Graphics, img: *Image, x: f32, y: f32) void {
//     self.drawImageWithOptions(img, x, y, .{});
// }

// pub fn drawImageWithOptions(self: *Graphics, img: *Image, x: f32, y: f32, opts: DrawOptions) void {
//     // Update the image's texture with current pixel data
//     img.update();

//     const vertices = [_]Vertex2D{
//         // Top-left
//         .{
//             .position = .{ x, y + @as(f32, @floatFromInt(img.height)) },
//             .color = opts.color,
//             .uv = .{ 0, 1 },
//         },
//         // Bottom-left
//         .{
//             .position = .{ x, y },
//             .color = opts.color,
//             .uv = .{ 0, 0 },
//         },
//         // Bottom-right
//         .{
//             .position = .{ x + @as(f32, @floatFromInt(img.width)), y },
//             .color = opts.color,
//             .uv = .{ 1, 0 },
//         },
//         // Top-right
//         .{
//             .position = .{ x + @as(f32, @floatFromInt(img.width)), y + @as(f32, @floatFromInt(img.height)) },
//             .color = opts.color,
//             .uv = .{ 1, 1 },
//         },
//     };

//     const indices = [_]u16{ 0, 1, 2, 0, 2, 3 };

//     // Upload vertex and index data
//     self.gfx.queue.writeBuffer(self.vertex_buffer, 0, &vertices);
//     self.gfx.queue.writeBuffer(self.index_buffer, 0, &indices);
//     self.gfx.queue.writeBuffer(self.uniform_buffer, 0, &opts);

//     // Get current texture view
//     const view = self.gfx.getCurrentTextureView();
//     defer view.release();

//     // Create command encoder
//     const encoder = self.gfx.device.createCommandEncoder(&zgpu.wgpu.CommandEncoderDescriptor{ .label = "Command encoder" }) orelse unreachable;
//     defer encoder.release();

//     // Begin render pass
//     const color_attachment = [_]zgpu.wgpu.ColorAttachment{.{
//         .view = view,
//         .load_op = .clear,
//         .store_op = .store,
//         .clear_value = .{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 1.0 },
//     }};

//     const render_pass_info = zgpu.wgpu.RenderPassDescriptor{
//         .color_attachments = &color_attachment,
//         .color_attachment_count = 1,
//         .depth_stencil_attachment = null,
//     };

//     const pass = encoder.beginRenderPass(&render_pass_info) orelse unreachable;
//     defer zgpu.endReleasePass(pass);

//     // Set pipeline and bind group
//     pass.setPipeline(self.gfx.lookupResource(self.pipeline));
//     pass.setBindGroup(0, self.gfx.lookupResource(self.bind_group), &.{});

//     // Set vertex and index buffers
//     pass.setVertexBuffer(0, self.vertex_buffer, 0, vertices.len * @sizeOf(Vertex2D));
//     pass.setIndexBuffer(self.index_buffer, .uint16, 0, indices.len * @sizeOf(u16));

//     // Draw
//     pass.drawIndexed(indices.len, 1, 0, 0, 0);

//     // Submit command buffer
//     const command_buffer = encoder.finish(null) orelse unreachable;
//     defer command_buffer.release();

//     self.gfx.submit(&.{command_buffer});
// }
