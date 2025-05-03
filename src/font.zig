const std = @import("std");
const Allocator = std.mem.Allocator;
const zgpu = @import("zgpu");
const hb = @import("harfbuzz");
const ft = @import("freetype");
const stb_rect_pack = @import("stb_rect_pack");

/// Margin around each glyph in the atlas.
const MARGIN_PX = 1;

const font_size = 18;

const FontMapping = enum(usize) {
    Latin = 0,
    Japanese = 1,
    Arabic = 2,
    Emoji = 3,
};

const RGBA = struct { r: u8, g: u8, b: u8, a: u8 };

const Range = struct {
    script: hb.Script, // Script used by the range.
    start: usize, // First byte index.
    end: usize, // Last byte index (inclusive).
};

pub const GlyphShape = struct {
    x: i32, // x position after shaping (in px).
    y: i32,
    glyph: GlyphInfo,
};

pub const GlyphInfo = struct {
    x: i32, // The x position in the atlas (in px).
    y: i32,
    width: i32, // Width of the glyph in the bitmap (in px).
    height: i32,
    bearing_x: i32, // Offset from the left edge of the bitmap to where the glyph starts (in px).
    bearing_y: i32,
    pixel_mode: ft.PixelMode,
};

var last_step: i128 = 0;
fn logTime(message: []const u8) void {
    const now = std.time.nanoTimestamp();
    std.debug.print("{s} took {d}ms\n", .{ message, @divTrunc(now - last_step, 1_000_000) });
    last_step = now;
}

const GlyphMap = std.AutoHashMap(u32, GlyphInfo);

pub const Font = struct {
    ft_face: ft.Face,
    hb_face: hb.Face,
    hb_font: hb.Font,
    glyphs: GlyphMap,

    pub fn init(allocator: Allocator, ft_lib: *ft.Library, data: []const u8) !Font {
        const ft_face = try ft_lib.initMemoryFace(data, 0);
        const hb_face = hb.Face.fromFreetypeFace(ft_face);
        const hb_font = try hb.Font.create(hb_face);
        return Font{
            .ft_face = ft_face,
            .hb_face = hb_face,
            .hb_font = hb_font,
            .glyphs = GlyphMap.init(allocator),
        };
    }
};

const latin = @embedFile("./assets/NotoSans-Regular.ttf");
const ar = @embedFile("./assets/NotoSansArabic-Regular.ttf");
const jp = @embedFile("./assets/NotoSansJP-Regular.ttf");
const kr = @embedFile("./assets/NotoSansKR-Regular.ttf");
const emoji = @embedFile("./assets/NotoColorEmoji-COLRv1.ttf");

/// Font encapsulates FreeType and HarfBuzz logic for shaping text. Generates font atlas texture in the `init()` method.
pub const Library = struct {
    allocator: Allocator,
    gctx: *zgpu.GraphicsContext,
    ft_lib: ft.Library,
    fonts: []Font,
    atlas_texture: ?zgpu.TextureHandle = null,
    atlas_size: u32 = 0,
    dpr: u32,

    pub fn init(allocator: Allocator, gctx: *zgpu.GraphicsContext, dpr: u32) !Library {
        var ft_lib = try ft.Library.init();
        const v = ft_lib.version();
        std.debug.print("FreeType version: {d}.{d}.{d}\n", .{ v.major, v.minor, v.patch });

        // Only initialize Latin font
        var fonts = try allocator.alloc(Font, 1);
        fonts[0] = try Font.init(allocator, &ft_lib, latin);
        try fonts[0].ft_face.setPixelSizes(0, font_size * dpr);
        const hb_font_size: i32 = font_size * @as(i32, @intCast(dpr)) * 64;
        fonts[0].hb_font.setScale(@intCast(hb_font_size), @intCast(hb_font_size));
        fonts[0].glyphs = GlyphMap.init(allocator);

        return Library{
            .allocator = allocator,
            .gctx = gctx,
            .ft_lib = ft_lib,
            .fonts = fonts,
            .atlas_texture = null,
            .atlas_size = 0,
            .dpr = dpr,
        };
    }

    /// Add a new font mapping to the library. Returns the index of the new font.
    pub fn addFontMapping(self: *Library, font_data: []const u8) !usize {
        const new_len = self.fonts.len + 1;
        self.fonts = try self.allocator.realloc(self.fonts, new_len);
        self.fonts[new_len - 1] = try Font.init(self.allocator, &self.ft_lib, font_data);
        try self.fonts[new_len - 1].ft_face.setPixelSizes(0, font_size * self.dpr);
        const hb_font_size: i32 = font_size * @as(i32, @intCast(self.dpr)) * 64;
        self.fonts[new_len - 1].hb_font.setScale(@intCast(hb_font_size), @intCast(hb_font_size));
        self.fonts[new_len - 1].glyphs = GlyphMap.init(self.allocator);
        return new_len - 1;
    }

    /// Generate the font atlas after all fonts have been added.
    pub fn finalizeAtlas(self: *Library) !void {
        const font_atlas = try generateFontAtlas(self.allocator, self.fonts);
        defer self.allocator.free(font_atlas.bitmap);

        const atlas_texture = self.gctx.createTexture(.{
            .usage = .{ .texture_binding = true, .copy_dst = true },
            .size = .{
                .width = font_atlas.size,
                .height = font_atlas.size,
                .depth_or_array_layers = 1,
            },
            .format = zgpu.imageInfoToTextureFormat(4, 1, false),
        });

        self.gctx.queue.writeTexture(
            .{ .texture = self.gctx.lookupResource(atlas_texture).? },
            .{ .bytes_per_row = font_atlas.size * 4, .rows_per_image = font_atlas.size },
            .{ .width = font_atlas.size, .height = font_atlas.size },
            u8,
            font_atlas.bitmap,
        );

        logTime("Uploading texture to GPU");
        self.atlas_texture = atlas_texture;
        self.atlas_size = font_atlas.size;
    }

    pub fn deinit(self: *Library) void {
        for (self.fonts) |*font| {
            font.hb_font.destroy();
            font.ft_face.deinit();
            font.glyphs.deinit();
        }
        self.allocator.free(self.fonts);
        self.ft_lib.deinit();
        if (self.atlas_texture) |tex| {
            self.gctx.releaseResource(tex);
        }
    }
};

pub fn shape(allocator: Allocator, fonts: []Font, value: []const u8, max_width: i32) ![]GlyphShape {
    _ = max_width; // autofix
    const ranges = try getRanges(allocator, value);
    defer allocator.free(ranges);

    var shapes = std.ArrayList(GlyphShape).init(allocator);
    var cursor_x: i32 = 0;
    var cursor_y: i32 = 0;

    const segments = try segment(allocator, value);
    defer allocator.free(segments);

    for (ranges) |range| {
        var buffer = try hb.Buffer.create();
        defer buffer.destroy();

        buffer.setDirection(scriptToDirection(range.script));
        buffer.setScript(range.script);

        buffer.addUTF8(value[range.start .. range.end + 1]);

        const fontId = scriptToFont(range.script) orelse {
            std.debug.print("No font for script {d}\n", .{@intFromEnum(range.script)});
            continue;
        };

        fonts[fontId].hb_font.shape(buffer, null);

        const infos = buffer.getGlyphInfos();
        const positions = buffer.getGlyphPositions() orelse return error.OutOfMemory;

        for (positions, infos) |pos, info| {
            // After shaping info.codepoint is a glyph index not unicode point.
            const glyph = fonts[fontId].glyphs.get(info.codepoint) orelse {
                std.debug.print("No glyph for {d}\n", .{info.codepoint});
                continue;
            };

            try shapes.append(GlyphShape{
                .x = cursor_x + (pos.x_offset >> 6) + glyph.bearing_x,
                .y = cursor_y + (pos.y_offset >> 6) - glyph.bearing_y,
                .glyph = glyph,
            });
            cursor_x += pos.x_advance >> 6;
            cursor_y += pos.y_advance >> 6;
        }
    }
    // std.debug.print("\n", .{});
    return shapes.toOwnedSlice();
}

/// Map Unicode codepoint to HarfBuzz script that will be used for shaping.
fn codepointToScript(codepoint: u64) hb.Script {
    return switch (codepoint) {
        0x0020...0x007F, 0x00A0...0x00FF, 0x0100...0x017F, 0x0180...0x024F => hb.Script.latin,
        0x0400...0x04FF => hb.Script.cyrillic,
        0x0900...0x097F => hb.Script.devanagari,
        0x0600...0x06FF => hb.Script.arabic,
        0x3041...0x3096 => hb.Script.hiragana,
        0x30A0...0x30FF => hb.Script.katakana,
        // 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xD7B0...0xD7FF => hb.Script.hangul,
        else => hb.Script.common,
    };
}

/// Map HarfBuzz script to font index.
fn scriptToFont(script: hb.Script) ?usize {
    return switch (script) {
        hb.Script.latin => @intFromEnum(FontMapping.Latin),
        hb.Script.cyrillic => @intFromEnum(FontMapping.Latin),
        hb.Script.devanagari => @intFromEnum(FontMapping.Latin),
        hb.Script.arabic => @intFromEnum(FontMapping.Arabic),
        hb.Script.common => @intFromEnum(FontMapping.Emoji),
        hb.Script.hiragana => @intFromEnum(FontMapping.Japanese),
        hb.Script.katakana => @intFromEnum(FontMapping.Japanese),
        else => null,
    };
}

/// Map HarfBuzz script to text direction.
fn scriptToDirection(script: hb.Script) hb.Direction {
    return switch (script) {
        hb.Script.arabic, hb.Script.hebrew => hb.Direction.rtl,
        else => hb.Direction.ltr,
    };
}

/// Generate font atlas texture from the input fonts.
fn generateFontAtlas(allocator: Allocator, fonts: []Font) !struct { size: u32, bitmap: []u8 } {
    logTime("Before init");
    var all_characters_len: u64 = 0;
    for (fonts) |f| {
        const count = f.ft_face.numGlyphs();
        std.debug.print("{s} ({d})\n", .{ f.ft_face.familyName() orelse "Unknown", count });
        all_characters_len += count;
    }

    std.debug.print("Total characters: {d}\n", .{all_characters_len});

    const sizes = try allocator.alloc([2]i32, all_characters_len);
    defer allocator.free(sizes);

    // Iterate over ranges.
    var i: u32 = 0;
    std.debug.print("num of fonts: {d}\n", .{fonts.len});
    for (fonts) |f| {
        const num_glyphs = f.ft_face.numGlyphs();
        for (0..num_glyphs) |j| {
            // For regular font it's not necessary to render the glyph to get size but for OT SVG it is.
            f.ft_face.loadGlyph(@intCast(j), .{
                .render = true,
                .color = f.ft_face.hasColor(),
            }) catch |err| {
                std.debug.print("Error loading glyph {d}, {d}\n", .{ j, i });
                return err;
            };
            const ft_glyph = f.ft_face.glyph();
            const ft_bitmap = ft_glyph.bitmap();
            const w = ft_bitmap.width();
            const h = ft_bitmap.rows();

            sizes[i] = if (w == 0 or h == 0) .{ 0, 0 } else .{
                @intCast(w + MARGIN_PX * 2),
                @intCast(h + MARGIN_PX * 2),
            };
            i += 1;
        }
    }
    logTime("Gathering sizes");

    // This is purely for debugging.
    var total_area: i32 = 0;
    for (sizes) |s| {
        total_area += s[0] * s[1];
    }
    std.debug.print("Total area: {d}px\n", .{total_area});

    const ATLAS_SIZE = 8100;
    const packing = .{
        .size = ATLAS_SIZE,
        .positions = try packAtlas(allocator, sizes, ATLAS_SIZE),
    };
    defer allocator.free(packing.positions);

    logTime("Packing atlas");

    const bitmap = try allocator.alloc(u8, @intCast(packing.size * packing.size * 4));
    @memset(bitmap, 0); // Clear the bitmap.

    // Once positions are known, we can generate the glyphs mapping and bitmap.
    i = 0;
    for (fonts) |*f| {
        for (0..f.ft_face.numGlyphs()) |j| {
            try f.ft_face.loadGlyph(@intCast(j), .{ .render = true, .color = f.ft_face.hasColor() });
            const ft_glyph = f.ft_face.glyph();

            const position = packing.positions[i];
            const packing_x: usize = @intCast(position[0]);
            const packing_y: usize = @intCast(position[1]);
            const ft_bitmap = ft_glyph.bitmap();

            const h = ft_bitmap.rows();
            const w = ft_bitmap.width();

            switch (ft_bitmap.pixelMode()) {
                .gray => {
                    for (0..h) |y| {
                        for (0..w) |x| {
                            const buffer = ft_bitmap.buffer() orelse continue; // Why is it crashing if I take this out of the loop?
                            const src = y * w + x;
                            const dst = ((packing_y + y + MARGIN_PX) * packing.size + packing_x + x + MARGIN_PX) * 4;

                            bitmap[dst + 0] = 255;
                            bitmap[dst + 1] = 255;
                            bitmap[dst + 2] = 255;
                            bitmap[dst + 3] = buffer[src];
                        }
                    }
                },
                .bgra => {
                    for (0..h) |y| {
                        for (0..w) |x| {
                            const buffer = ft_bitmap.buffer() orelse continue;
                            const src = (y * w + x) * 4;
                            const dst = ((packing_y + y + MARGIN_PX) * packing.size + packing_x + x + MARGIN_PX) * 4;

                            bitmap[dst + 0] = buffer[src + 2];
                            bitmap[dst + 1] = buffer[src + 1];
                            bitmap[dst + 2] = buffer[src + 0];
                            bitmap[dst + 3] = buffer[src + 3];
                        }
                    }
                },
                else => unreachable,
            }

            try f.glyphs.put(@intCast(j), GlyphInfo{
                .x = packing.positions[i][0],
                .y = packing.positions[i][1],
                .width = sizes[i][0],
                .height = sizes[i][1],
                .bearing_x = ft_glyph.bitmapLeft() - MARGIN_PX,
                .bearing_y = ft_glyph.bitmapTop() - MARGIN_PX,
                .pixel_mode = ft_bitmap.pixelMode(),
            });

            i += 1;
        }
    }
    logTime("Copying bitmaps");

    return .{ .size = packing.size, .bitmap = bitmap };
}

/// Split the input string into list of ranges with the same script.
fn getRanges(allocator: Allocator, value: []const u8) ![]Range {
    var ranges = std.ArrayList(Range).init(allocator);
    var utf8 = try std.unicode.Utf8View.init(value);
    var iterator = utf8.iterator();

    var current_range: ?Range = null;
    var byte_index: usize = 0;

    while (iterator.nextCodepointSlice()) |slice| {
        const codepoint = try std.unicode.utf8Decode(slice);
        const script = codepointToScript(codepoint);
        // std.debug.print("{X}\n", .{codepoint});

        if (current_range) |*range| {
            if (range.script == script) {
                range.end = byte_index + slice.len - 1;
            } else {
                try ranges.append(range.*);
                current_range = Range{
                    .script = script,
                    .start = byte_index,
                    .end = byte_index + slice.len - 1,
                };
            }
        } else {
            current_range = Range{
                .script = script,
                .start = byte_index,
                .end = byte_index + slice.len - 1,
            };
        }
        byte_index += slice.len;
    }
    // std.debug.print("\n", .{});

    if (current_range) |range| {
        try ranges.append(range);
    }

    return ranges.toOwnedSlice();
}

/// Segment text into words using ICU4X. Returns a slice of indices where words start or end.
pub fn segment(allocator: Allocator, value: []const u8) ![]u32 {
    _ = value; // autofix

    var segments = std.ArrayList(u32).init(allocator);
    return segments.toOwnedSlice();
}

/// Wrapper for calling stb_rect_pack.
fn packAtlas(allocator: Allocator, sizes: [][2]i32, size: comptime_int) ![][2]i32 {
    const rectangles = try allocator.alloc(stb_rect_pack.c.stbrp_rect, sizes.len);
    defer allocator.free(rectangles);

    for (sizes, 0..) |s, i| {
        rectangles[i] = .{
            .id = @intCast(i),
            .x = 0,
            .y = 0,
            .w = s[0],
            .h = s[1],
            .was_packed = 0,
        };
    }

    const nodes = try allocator.alloc(stb_rect_pack.c.stbrp_node, size * 2);
    defer allocator.free(nodes);

    var context: stb_rect_pack.c.stbrp_context = .{};
    stb_rect_pack.c.stbrp_init_target(@ptrCast(&context), size, size, nodes.ptr, @intCast(nodes.len));
    const result = stb_rect_pack.c.stbrp_pack_rects(@ptrCast(&context), rectangles.ptr, @intCast(rectangles.len));

    if (result == 0) {
        return error.FailedToPackAtlas;
    }

    const positions = try allocator.alloc([2]i32, sizes.len);
    for (rectangles, 0..) |rect, i| {
        positions[i] = .{ rect.x, rect.y };
    }

    return positions;
}
