const std = @import("std");
const zgpu = @import("zgpu");
const obj = @import("obj");
const jpeg = @import("jpeg");
const png = @import("png");
const zmath = @import("zmath");
const img_module = @import("image");
const Image = @import("Image.zig").Image;

const ResourceManager = @This();

pub const VertexAttr = struct {
    position: [3]f32,
    color: [4]f32,
    uv: [2]f32,
    normal: [3]f32,
};

pub fn loadGeometryFromObj(
    allocator: std.mem.Allocator,
    path: []const u8,
) !std.ArrayList(VertexAttr) {
    // open file
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // read file
    const obj_file_contents = try file.readToEndAlloc(allocator, 1024 * 1024 * 10);
    defer allocator.free(obj_file_contents);

    // Load the OBJ model
    var obj_model = try obj.parseObj(allocator, obj_file_contents);
    defer obj_model.deinit(allocator);

    var vertex_data = std.ArrayList(VertexAttr).init(allocator);
    errdefer vertex_data.deinit();

    // Process each mesh in the OBJ model
    for (obj_model.meshes) |mesh| {
        var face_start: usize = 0;

        // Process each face in the mesh (using num_vertices to determine faces)
        for (mesh.num_vertices) |num_verts_in_face| {
            // Handle triangles and quads (or faces with more vertices)
            for (1..num_verts_in_face - 1) |i| {
                // For each triangle in the face, process 3 vertices
                // First vertex is always at face_start
                // The other two form the triangle (like a triangle fan)
                const indices_to_process = [_]usize{ face_start, face_start + i, face_start + i + 1 };

                for (indices_to_process) |idx| {
                    const mesh_index = mesh.indices[idx];

                    // Get position data if available
                    var px: f32 = 0.0;
                    var py: f32 = 0.0;
                    var pz: f32 = 0.0;

                    if (mesh_index.vertex) |vertex_idx| {
                        if (vertex_idx * 3 + 2 < obj_model.vertices.len) {
                            // OBJ uses Y-up convention, but our code uses Z-up
                            px = obj_model.vertices[vertex_idx * 3];
                            py = -obj_model.vertices[vertex_idx * 3 + 2];
                            pz = obj_model.vertices[vertex_idx * 3 + 1];
                        }
                    }

                    // Get normal data if available
                    var nx: f32 = 0.0;
                    var ny: f32 = 0.0;
                    var nz: f32 = 0.0;

                    if (mesh_index.normal) |normal_idx| {
                        if (normal_idx * 3 + 2 < obj_model.normals.len) {
                            nx = obj_model.normals[normal_idx * 3];
                            ny = -obj_model.normals[normal_idx * 3 + 2];
                            nz = obj_model.normals[normal_idx * 3 + 1];
                        }
                    }

                    // Use white as default color
                    const r: f32 = 1.0;
                    const g: f32 = 1.0;
                    const b: f32 = 1.0;

                    // Get texture coordinates if available - THIS IS CRITICAL
                    var u: f32 = 0.0;
                    var v: f32 = 0.0;

                    if (mesh_index.tex_coord) |uv_idx| {
                        if (uv_idx * 2 + 1 < obj_model.tex_coords.len) {
                            // OBJ format stores UV with bottom-left origin (0,0)
                            // Make sure U is clamped to [0,1] range
                            u = @max(0.0, @min(1.0, obj_model.tex_coords[uv_idx * 2]));
                            // Flip V coordinate as OBJ format uses bottom-left origin
                            // and we want top-left origin for WebGPU
                            v = 1.0 - @max(0.0, @min(1.0, obj_model.tex_coords[uv_idx * 2 + 1]));

                            // Debug print - uncomment if needed
                            // std.debug.print("UV: ({d}, {d})\n", .{ u, v });
                        }
                    }

                    // Add position, normal, color and UV to the point data
                    try vertex_data.append(VertexAttr{
                        .position = [3]f32{ px, py, pz },
                        .normal = [3]f32{ nx, ny, nz },
                        .color = [3]f32{ r, g, b },
                        .uv = [2]f32{ u, v },
                        .tangent = [3]f32{ 0.0, 0.0, 0.0 },
                        .bitangent = [3]f32{ 0.0, 0.0, 0.0 },
                    });
                }
            }

            // Move to the next face
            face_start += num_verts_in_face;
        }
    }

    // Compute tangent, bitangent, and normal vectors for each triangle
    const triangle_count = @divFloor(vertex_data.items.len, 3);

    var t: usize = 0;
    while (t < triangle_count) : (t += 1) {
        const triangle_vertices = [3]VertexAttr{
            vertex_data.items[3 * t],
            vertex_data.items[3 * t + 1],
            vertex_data.items[3 * t + 2],
        };

        // For each vertex in the triangle, compute its own TBN frame using its normal
        for (0..3) |k| {
            const tbn = computeTbnWithNormal(triangle_vertices, triangle_vertices[k].normal);

            // Extract TBN columns
            const T: @Vector(3, f32) = @Vector(3, f32){ tbn[0][0], tbn[0][1], tbn[0][2] };
            const B: @Vector(3, f32) = @Vector(3, f32){ tbn[1][0], tbn[1][1], tbn[1][2] };
            const N: @Vector(3, f32) = @Vector(3, f32){ tbn[2][0], tbn[2][1], tbn[2][2] };

            // Assign to the current vertex only
            vertex_data.items[3 * t + k].tangent = T;
            vertex_data.items[3 * t + k].bitangent = B;
            vertex_data.items[3 * t + k].normal = N;
        }
    }

    return vertex_data;
}

pub fn loadShaderModule(al: std.mem.Allocator, path: []const u8, device: zgpu.wgpu.Device) !zgpu.wgpu.ShaderModule {
    // open file
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    // read file
    const contents = try file.readToEndAllocOptions(
        al,
        1024 * 16,
        null,
        @alignOf(u8),
        0,
    );
    defer al.free(contents);

    return zgpu.createWgslShaderModule(device, contents, null);
}

pub fn loadTexture(
    allocator: std.mem.Allocator,
    gfx: *zgpu.GraphicsContext,
    path: []const u8,
    texture_view: *?zgpu.TextureViewHandle,
) !zgpu.TextureHandle {
    const ext = std.fs.path.extension(path);
    const image =
        if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg"))
            try jpeg.load(allocator, path)
        else
            try png.load(allocator, path);
    defer image.free(allocator);

    const bounds = image.bounds();
    const width: u32 = @intCast(bounds.dX());
    const height: u32 = @intCast(bounds.dY());

    const texture_pixels = try image.rgbaPixels(allocator);
    defer allocator.free(texture_pixels);

    const mip_level_count = bitWidth(@max(width, height));

    const texture_desc = zgpu.wgpu.TextureDescriptor{
        .dimension = .tdim_2d,
        .format = .rgba8_unorm,
        .mip_level_count = mip_level_count,
        .sample_count = 1,
        .size = .{
            .width = width,
            .height = height,
            .depth_or_array_layers = 1,
        },
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .view_format_count = 0,
        .view_formats = null,
    };

    const texture = gfx.createTexture(texture_desc);

    if (texture_view.*) |_| {
        // do nothing if exists
    } else {
        texture_view.* = gfx.createTextureView(texture, .{
            .aspect = .all,
            .base_array_layer = 0,
            .array_layer_count = 1,
            .base_mip_level = 0,
            .mip_level_count = texture_desc.mip_level_count,
            .dimension = .tvdim_2d,
            .format = texture_desc.format,
        });
    }

    writeMipMaps(
        allocator,
        gfx,
        texture,
        texture_desc.size,
        texture_pixels,
    );

    return texture;
}

fn writeMipMaps(
    allocator: std.mem.Allocator,
    gfx: *zgpu.GraphicsContext,
    texture_handle: zgpu.TextureHandle,
    texture_size: zgpu.wgpu.Extent3D,
    texture_pixels: []u8,
) void {
    const texture = gfx.lookupResource(texture_handle) orelse unreachable;

    // Arguments telling which part of the texture to upload
    var destination = zgpu.wgpu.ImageCopyTexture{
        .texture = texture,
        .mip_level = 0,
        .origin = .{ .x = 0, .y = 0, .z = 0 },
        .aspect = .all,
    };

    var mip_level_size = texture_size;
    var previous_level_pixels: ?[]u8 = null;

    // Calculate number of mip levels based on the largest dimension
    const max_dimension = @max(texture_size.width, texture_size.height);
    const mip_level_count = bitWidth(max_dimension);

    var level: u32 = 0;
    while (level < mip_level_count) : (level += 1) {
        // Calculate dimensions for this mip level
        const width = texture_size.width >> @intCast(level);
        const height = texture_size.height >> @intCast(level);

        // Calculate bytes per row with proper alignment (256-byte alignment for WebGPU)
        const bytes_per_row = (4 * width + 255) & ~@as(u32, 255);

        // Allocate space for current mip level with proper row alignment
        const row_pitch = bytes_per_row;
        const buffer_size = row_pitch * height;
        const pixels = allocator.alloc(u8, buffer_size) catch break;
        defer allocator.free(pixels);

        // Clear the buffer first
        @memset(pixels, 0);

        if (level == 0) {
            // For the first level, copy the input texture data row by row to handle alignment
            var y: usize = 0;
            while (y < height) : (y += 1) {
                const src_offset = y * width * 4;
                const dst_offset = y * row_pitch;
                const row_bytes = width * 4;
                @memcpy(pixels[dst_offset..][0..row_bytes], texture_pixels[src_offset..][0..row_bytes]);
            }
        } else {
            // Generate mip level data from previous level
            const prev_width = texture_size.width >> @intCast(level - 1);
            for (0..height) |j| {
                for (0..width) |i| {
                    const dst_offset = j * row_pitch + i * 4;

                    // Calculate source pixels from previous level
                    const src_x = i * 2;
                    const src_y = j * 2;
                    const prev_row_pitch = (4 * prev_width + 255) & ~@as(u32, 255);

                    const p00_idx = src_y * prev_row_pitch + src_x * 4;
                    const p01_idx = src_y * prev_row_pitch + (src_x + 1) * 4;
                    const p10_idx = (src_y + 1) * prev_row_pitch + src_x * 4;
                    const p11_idx = (src_y + 1) * prev_row_pitch + (src_x + 1) * 4;

                    // Average each color component
                    inline for (0..4) |component| {
                        const sum = @as(u16, previous_level_pixels.?[p00_idx + component]) +
                            @as(u16, previous_level_pixels.?[p01_idx + component]) +
                            @as(u16, previous_level_pixels.?[p10_idx + component]) +
                            @as(u16, previous_level_pixels.?[p11_idx + component]);
                        pixels[dst_offset + component] = @truncate(sum / 4);
                    }
                }
            }
        }

        // Upload the mip level to GPU
        destination.mip_level = level;

        // describes the layout of the data in the buffer
        const data_layout = zgpu.wgpu.TextureDataLayout{
            .offset = 0,
            .bytes_per_row = bytes_per_row,
            .rows_per_image = height,
        };

        mip_level_size.width = width;
        mip_level_size.height = height;

        gfx.queue.writeTexture(
            destination,
            data_layout,
            mip_level_size,
            u8,
            pixels,
        );

        // Update for next iteration
        if (previous_level_pixels) |prev_pixels| {
            allocator.free(prev_pixels);
        }
        previous_level_pixels = allocator.dupe(u8, pixels) catch break;
    }

    // Clean up
    if (previous_level_pixels) |prev_pixels| {
        allocator.free(prev_pixels);
    }
}

fn bitWidth(m: u32) u32 {
    if (m == 0) return 0;
    var width: u32 = 0;
    var value = m;
    while (value > 0) : (width += 1) {
        value >>= 1;
    }
    return width;
}

/// Compute the TBN local to a triangle face from its corners and return it as
/// a matrix whose columns are the T, B and N vectors.
pub fn computeTbn(corners: [3]VertexAttr) zmath.Mat {
    const pos_vec = zmath.loadArr3(corners[0].position);
    const pos_vec1 = zmath.loadArr3(corners[1].position);
    const pos_vec2 = zmath.loadArr3(corners[2].position);
    const uv_vec = zmath.loadArr2(corners[0].uv);
    const uv_vec1 = zmath.loadArr2(corners[1].uv);
    const uv_vec2 = zmath.loadArr2(corners[2].uv);

    const e_pos1 = pos_vec1 - pos_vec;
    const e_pos2 = pos_vec2 - pos_vec;

    const eUV1 = uv_vec1 - uv_vec;
    const eUV2 = uv_vec2 - uv_vec;

    // Calculate tangent (T)
    const T = zmath.normalize3(
        e_pos1 * zmath.splat(zmath.Vec, eUV2[1]) -
            e_pos2 * zmath.splat(zmath.Vec, eUV1[1]),
    );

    // Calculate bitangent (B)
    const B = zmath.normalize3(
        e_pos2 * zmath.splat(zmath.Vec, eUV1[0]) -
            e_pos1 * zmath.splat(zmath.Vec, eUV2[0]),
    );

    // Calculate normal (N) as cross product of T and B
    const N = zmath.cross3(T, B);

    // Return matrix with T, B, N as columns
    return zmath.loadMat(
        &.{
            T[0], B[0], N[0], 0.0,
            T[1], B[1], N[1], 0.0,
            T[2], B[2], N[2], 0.0,
            0.0,  0.0,  0.0,  1.0,
        },
    );
}

/// Compute the TBN with an expected normal direction to improve smoothness and orientation
pub fn computeTbnWithNormal(corners: [3]VertexAttr, expected_normal: [3]f32) zmath.Mat {
    // Initial calculation as in the original function
    const pos_vec = zmath.loadArr3(corners[0].position);
    const pos_vec1 = zmath.loadArr3(corners[1].position);
    const pos_vec2 = zmath.loadArr3(corners[2].position);
    const uv_vec = zmath.loadArr2(corners[0].uv);
    const uv_vec1 = zmath.loadArr2(corners[1].uv);
    const uv_vec2 = zmath.loadArr2(corners[2].uv);

    const e_pos1 = pos_vec1 - pos_vec;
    const e_pos2 = pos_vec2 - pos_vec;

    const eUV1 = uv_vec1 - uv_vec;
    const eUV2 = uv_vec2 - uv_vec;

    // Calculate tangent (T) and bitangent (B)
    var T = zmath.normalize3(
        e_pos1 * zmath.splat(zmath.Vec, eUV2[1]) -
            e_pos2 * zmath.splat(zmath.Vec, eUV1[1]),
    );

    var B = zmath.normalize3(
        e_pos2 * zmath.splat(zmath.Vec, eUV1[0]) -
            e_pos1 * zmath.splat(zmath.Vec, eUV2[0]),
    );

    // Compute the geometric normal
    var N = zmath.normalize3(zmath.cross3(T, B));

    // Load the expected normal
    const expected_N = zmath.normalize3(zmath.loadArr3(expected_normal));

    // Fix overall orientation - if N and expectedN point in opposite directions
    const dot_product = zmath.dot3(N, expected_N)[0];
    if (dot_product < 0.0) {
        T = T * zmath.splat(zmath.Vec, -1.0);
        B = B * zmath.splat(zmath.Vec, -1.0);
        N = N * zmath.splat(zmath.Vec, -1.0);
    }

    // Use the expected normal
    N = expected_N;

    // Orthogonalize T with respect to N
    // T = T - (T·N)N
    const t_dot_n = zmath.dot3(T, N)[0];
    T = zmath.normalize3(T - (N * zmath.splat(zmath.Vec, t_dot_n)));

    // Recompute B from N and T
    B = zmath.normalize3(zmath.cross3(N, T));

    // Return matrix with T, B, N as columns
    return zmath.loadMat(
        &.{
            T[0], B[0], N[0], 0.0,
            T[1], B[1], N[1], 0.0,
            T[2], B[2], N[2], 0.0,
            0.0,  0.0,  0.0,  1.0,
        },
    );
}

/// Load an image from a file and return it as a Zonk Image
pub fn loadImage(
    allocator: std.mem.Allocator,
    gfx: *zgpu.GraphicsContext,
    path: []const u8,
) !*Image {
    _ = gfx;

    // Use the same loading pattern as loadTexture
    const ext = std.fs.path.extension(path);
    var loaded_image = if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg"))
        try jpeg.load(allocator, path)
    else
        try png.load(allocator, path);
    defer loaded_image.free(allocator);

    // Convert to RGBA format regardless of source format
    const rgba_image = try imageToRGBA(allocator, &loaded_image);

    const img = try allocator.create(Image);
    img.* = .{
        .rgba_image = rgba_image,
        .allocator = allocator,
    };

    return img;
}

/// Convert any image format to RGBA
fn imageToRGBA(allocator: std.mem.Allocator, img: *img_module.Image) !img_module.RGBAImage {
    const size = img.bounds().size();
    const width = size.x;
    const height = size.y;

    switch (img.*) {
        .RGBA => |rgba| {
            // If it's already RGBA and the right size, we can use it directly
            const expected_len = @as(usize, @intCast(width * height * 4));
            if (rgba.pixels.len == expected_len) {
                return rgba;
            } else {
                // Fall back to conversion
                return imageToRGBASlow(allocator, img);
            }
        },
        else => {
            // For any other format (NRGBA, Paletted, etc.), convert to RGBA
            return imageToRGBASlow(allocator, img);
        },
    }
}

/// Convert any image format to RGBA using slow but universal method
fn imageToRGBASlow(allocator: std.mem.Allocator, img: *img_module.Image) !img_module.RGBAImage {
    const size = img.bounds().size();
    const width = size.x;
    const height = size.y;

    // Create a new RGBA image
    var rgba_image = try img_module.RGBAImage.init(allocator, img_module.Rectangle{
        .min = .{ .x = 0, .y = 0 },
        .max = .{ .x = width, .y = height },
    });

    const pixels = try img.rgbaPixels(allocator);
    defer allocator.free(pixels);
    @memcpy(rgba_image.pixels[0..], pixels[0..]);

    return rgba_image;
}
