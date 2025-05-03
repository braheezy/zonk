const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const errors = @import("errors.zig");
const Library = @import("Library.zig");
const Tag = @import("tag.zig").Tag;
const Error = errors.Error;
const intToError = errors.intToError;

pub const GlyphMetrics = c.FT_Glyph_Metrics;
pub const Matrix = c.FT_Matrix;
pub const Vector = c.FT_Vector;
pub const Color = c.FT_Color;

pub const Face = struct {
    handle: c.FT_Face,

    pub fn deinit(self: Face) void {
        _ = c.FT_Done_Face(self.handle);
    }

    /// Increment the counter of the face.
    pub fn ref(self: Face) void {
        _ = c.FT_Reference_Face(self.handle);
    }

    /// A macro that returns true whenever a face object contains some
    /// embedded bitmaps. See the available_sizes field of the FT_FaceRec structure.
    pub fn hasFixedSizes(self: Face) bool {
        return c.FT_HAS_FIXED_SIZES(self.handle);
    }

    /// A macro that returns true whenever a face object contains tables for
    /// color glyphs.
    pub fn hasColor(self: Face) bool {
        return c.FT_HAS_COLOR(self.handle);
    }

    /// A macro that returns true whenever a face object contains an ‘sbix’
    /// OpenType table and outline glyphs.
    pub fn hasSBIX(self: Face) bool {
        return c.FT_HAS_SBIX(self.handle);
    }

    /// A macro that returns true whenever a face object contains some
    /// multiple masters.
    pub fn hasMultipleMasters(self: Face) bool {
        return c.FT_HAS_MULTIPLE_MASTERS(self.handle);
    }

    /// A macro that returns true whenever a face object contains a scalable
    /// font face (true for TrueType, Type 1, Type 42, CID, OpenType/CFF,
    /// and PFR font formats).
    pub fn isScalable(self: Face) bool {
        return c.FT_IS_SCALABLE(self.handle);
    }

    /// Select a given charmap by its encoding tag (as listed in freetype.h).
    pub fn selectCharmap(self: Face, encoding: Encoding) Error!void {
        return intToError(c.FT_Select_Charmap(self.handle, @intFromEnum(encoding)));
    }

    /// Call FT_Request_Size to request the nominal size (in points).
    pub fn setCharSize(
        self: Face,
        char_width: i32,
        char_height: i32,
        horz_resolution: u16,
        vert_resolution: u16,
    ) Error!void {
        return intToError(c.FT_Set_Char_Size(
            self.handle,
            char_width,
            char_height,
            horz_resolution,
            vert_resolution,
        ));
    }

    /// Select a bitmap strike. To be more precise, this function sets the
    /// scaling factors of the active FT_Size object in a face so that bitmaps
    /// from this particular strike are taken by FT_Load_Glyph and friends.
    pub fn selectSize(self: Face, idx: i32) Error!void {
        return intToError(c.FT_Select_Size(self.handle, idx));
    }

    /// Return the glyph index of a given character code. This function uses
    /// the currently selected charmap to do the mapping.
    pub fn getCharIndex(self: Face, char: u32) ?u32 {
        const i = c.FT_Get_Char_Index(self.handle, char);
        return if (i == 0) null else i;
    }

    /// Load a glyph into the glyph slot of a face object.
    pub fn loadGlyph(self: Face, glyph_index: u32, load_flags: LoadFlags) Error!void {
        return intToError(c.FT_Load_Glyph(
            self.handle,
            glyph_index,
            @bitCast(load_flags),
        ));
    }

    /// Convert a given glyph image to a bitmap.
    pub fn renderGlyph(self: Face, render_mode: RenderMode) Error!void {
        return intToError(c.FT_Render_Glyph(
            self.handle.*.glyph,
            @intFromEnum(render_mode),
        ));
    }

    /// Return a pointer to a given SFNT table stored within a face.
    pub fn getSfntTable(self: Face, comptime tag: SfntTag) ?*tag.DataType() {
        return @ptrCast(@alignCast(c.FT_Get_Sfnt_Table(
            self.handle,
            @intFromEnum(tag),
        )));
    }

    /// Retrieve the number of name strings in the SFNT ‘name’ table.
    pub fn getSfntNameCount(self: Face) usize {
        return @intCast(c.FT_Get_Sfnt_Name_Count(self.handle));
    }

    /// Retrieve a string of the SFNT ‘name’ table for a given index.
    pub fn getSfntName(self: Face, i: usize) Error!c.FT_SfntName {
        var name: c.FT_SfntName = undefined;
        const res = c.FT_Get_Sfnt_Name(self.handle, @intCast(i), &name);
        return if (intToError(res)) |_| name else |err| err;
    }

    /// Load any SFNT font table into client memory.
    pub fn loadSfntTable(
        self: Face,
        alloc: Allocator,
        tag: Tag,
    ) (Allocator.Error || Error)!?[]u8 {
        const tag_c: c_ulong = @intCast(@as(u32, @bitCast(tag)));

        // Get the length of the table in bytes
        var len: c_ulong = 0;
        var res = c.FT_Load_Sfnt_Table(self.handle, tag_c, 0, null, &len);
        _ = intToError(res) catch |err| return err;

        // If our length is zero we don't have a table.
        if (len == 0) return null;

        // Allocate a buffer to hold the table and load it
        const buf = try alloc.alloc(u8, len);
        errdefer alloc.free(buf);
        res = c.FT_Load_Sfnt_Table(self.handle, tag_c, 0, buf.ptr, &len);
        _ = intToError(res) catch |err| return err;

        return buf;
    }

    /// Check whether a given SFNT table is available in a face.
    pub fn hasSfntTable(self: Face, tag: Tag) bool {
        const tag_c: c_ulong = @intCast(@as(u32, @bitCast(tag)));
        var len: c_ulong = 0;
        const res = c.FT_Load_Sfnt_Table(self.handle, tag_c, 0, null, &len);
        _ = intToError(res) catch return false;
        return len != 0;
    }

    /// Retrieve the font variation descriptor for a font.
    pub fn getMMVar(self: Face) Error!*c.FT_MM_Var {
        var result: *c.FT_MM_Var = undefined;
        const res = c.FT_Get_MM_Var(self.handle, @ptrCast(&result));
        return if (intToError(res)) |_| result else |err| err;
    }

    /// Get the design coordinates of the currently selected interpolated font.
    pub fn getVarDesignCoordinates(self: Face, coords: []c.FT_Fixed) Error!void {
        const res = c.FT_Get_Var_Design_Coordinates(
            self.handle,
            @intCast(coords.len),
            coords.ptr,
        );
        return intToError(res);
    }

    /// Choose an interpolated font design through design coordinates.
    pub fn setVarDesignCoordinates(self: Face, coords: []c.FT_Fixed) Error!void {
        const res = c.FT_Set_Var_Design_Coordinates(
            self.handle,
            @intCast(coords.len),
            coords.ptr,
        );
        return intToError(res);
    }

    /// Set the transformation that is applied to glyph images when they are
    /// loaded into a glyph slot through FT_Load_Glyph.
    pub fn setTransform(
        self: Face,
        matrix: ?*const c.FT_Matrix,
        delta: ?*const c.FT_Vector,
    ) void {
        c.FT_Set_Transform(
            self.handle,
            @constCast(@ptrCast(matrix)),
            @constCast(@ptrCast(delta)),
        );
    }

    pub fn setPixelSizes(self: Face, pixel_width: u32, pixel_height: u32) Error!void {
        return intToError(c.FT_Set_Pixel_Sizes(self.handle, pixel_width, pixel_height));
    }

    pub fn numGlyphs(self: Face) u32 {
        return @intCast(self.handle.*.num_glyphs);
    }

    pub fn familyName(self: Face) ?[:0]const u8 {
        return if (self.handle.*.family_name) |family|
            std.mem.span(@as([*:0]const u8, @ptrCast(family)))
        else
            null;
    }
    pub fn glyph(self: Face) GlyphSlot {
        return .{ .handle = self.handle.*.glyph };
    }
};

/// An enumeration to specify indices of SFNT tables loaded and parsed by
/// FreeType during initialization of an SFNT font. Used in the
/// FT_Get_Sfnt_Table API function.
pub const SfntTag = enum(c_int) {
    head = c.FT_SFNT_HEAD,
    maxp = c.FT_SFNT_MAXP,
    os2 = c.FT_SFNT_OS2,
    hhea = c.FT_SFNT_HHEA,
    vhea = c.FT_SFNT_VHEA,
    post = c.FT_SFNT_POST,
    pclt = c.FT_SFNT_PCLT,

    /// The data type for a given sfnt tag.
    pub fn DataType(comptime self: SfntTag) type {
        return switch (self) {
            .os2 => c.TT_OS2,
            .head => c.TT_Header,
            .post => c.TT_Postscript,
            .hhea => c.TT_HoriHeader,
            else => unreachable, // As-needed...
        };
    }
};

/// An enumeration to specify character sets supported by charmaps. Used in the
/// FT_Select_Charmap API function.
pub const Encoding = enum(u31) {
    none = c.FT_ENCODING_NONE,
    ms_symbol = c.FT_ENCODING_MS_SYMBOL,
    unicode = c.FT_ENCODING_UNICODE,
    sjis = c.FT_ENCODING_SJIS,
    prc = c.FT_ENCODING_PRC,
    big5 = c.FT_ENCODING_BIG5,
    wansung = c.FT_ENCODING_WANSUNG,
    johab = c.FT_ENCODING_JOHAB,
    adobe_standard = c.FT_ENCODING_ADOBE_STANDARD,
    adobe_expert = c.FT_ENCODING_ADOBE_EXPERT,
    adobe_custom = c.FT_ENCODING_ADOBE_CUSTOM,
    adobe_latin_1 = c.FT_ENCODING_ADOBE_LATIN_1,
    old_latin_2 = c.FT_ENCODING_OLD_LATIN_2,
    apple_roman = c.FT_ENCODING_APPLE_ROMAN,
};

/// https://freetype.org/freetype2/docs/reference/ft2-glyph_retrieval.html#ft_render_mode
pub const RenderMode = enum(c_uint) {
    normal = c.FT_RENDER_MODE_NORMAL,
    light = c.FT_RENDER_MODE_LIGHT,
    mono = c.FT_RENDER_MODE_MONO,
    lcd = c.FT_RENDER_MODE_LCD,
    lcd_v = c.FT_RENDER_MODE_LCD_V,
    sdf = c.FT_RENDER_MODE_SDF,
};

/// A list of bit field constants for FT_Load_Glyph to indicate what kind of
/// operations to perform during glyph loading.
pub const LoadFlags = packed struct {
    no_scale: bool = false,
    no_hinting: bool = false,
    render: bool = false,
    no_bitmap: bool = false,
    vertical_layout: bool = false,
    force_autohint: bool = false,
    crop_bitmap: bool = false,
    pedantic: bool = false,
    ignore_global_advance_with: bool = false,
    no_recurse: bool = false,
    ignore_transform: bool = false,
    monochrome: bool = false,
    linear_design: bool = false,
    no_autohint: bool = false,
    _padding1: u1 = 0,
    target_normal: bool = false,
    target_light: bool = false,
    target_mono: bool = false,
    target_lcd: bool = false,
    target_lcd_v: bool = false,
    color: bool = false,
    compute_metrics: bool = false,
    bitmap_metrics_only: bool = false,
    _padding2: u1 = 0,
    no_svg: bool = false,
    _padding3: u7 = 0,

    test {
        // This must always be an i32 size so we can bitcast directly.
        const testing = std.testing;
        try testing.expectEqual(@sizeOf(i32), @sizeOf(LoadFlags));
    }

    test "bitcast" {
        const testing = std.testing;
        const cval: i32 = c.FT_LOAD_RENDER | c.FT_LOAD_PEDANTIC | c.FT_LOAD_COLOR;
        const flags = @as(LoadFlags, @bitCast(cval));
        try testing.expect(!flags.no_hinting);
        try testing.expect(flags.render);
        try testing.expect(flags.pedantic);
        try testing.expect(flags.color);
    }
};

pub const GlyphSlot = struct {
    pub const SubGlyphInfo = struct {
        index: i32,
        flags: c_uint,
        arg1: i32,
        arg2: i32,
        transform: Matrix,
    };

    handle: c.FT_GlyphSlot,

    pub fn library(self: GlyphSlot) Library {
        return .{ .handle = self.handle.*.library };
    }

    pub fn face(self: GlyphSlot) Face {
        return .{ .handle = self.handle.*.face };
    }

    pub fn next(self: GlyphSlot) GlyphSlot {
        return .{ .handle = self.handle.*.next };
    }

    pub fn glyphIndex(self: GlyphSlot) u32 {
        return self.handle.*.glyph_index;
    }

    pub fn metrics(self: GlyphSlot) GlyphMetrics {
        return self.handle.*.metrics;
    }

    pub fn linearHoriAdvance(self: GlyphSlot) i32 {
        return @intCast(self.handle.*.linearHoriAdvance);
    }

    pub fn linearVertAdvance(self: GlyphSlot) i32 {
        return @intCast(self.handle.*.linearVertAdvance);
    }

    pub fn advance(self: GlyphSlot) Vector {
        return self.handle.*.advance;
    }

    pub fn format(self: GlyphSlot) GlyphFormat {
        return @enumFromInt(self.handle.*.format);
    }

    pub fn ownBitmap(self: GlyphSlot) Error!void {
        try intToError(c.FT_GlyphSlot_Own_Bitmap(self.handle));
    }

    pub fn bitmap(self: GlyphSlot) Bitmap {
        return .{ .handle = self.handle.*.bitmap };
    }

    pub fn bitmapLeft(self: GlyphSlot) i32 {
        return self.handle.*.bitmap_left;
    }

    pub fn bitmapTop(self: GlyphSlot) i32 {
        return self.handle.*.bitmap_top;
    }

    // pub fn outline(self: GlyphSlot) ?Outline {
    //     return if (self.format() == .outline) .{ .handle = &self.handle.*.outline } else null;
    // }

    pub fn lsbDelta(self: GlyphSlot) i32 {
        return @intCast(self.handle.*.lsb_delta);
    }

    pub fn rsbDelta(self: GlyphSlot) i32 {
        return @intCast(self.handle.*.rsb_delta);
    }

    pub fn render(self: GlyphSlot, render_mode: RenderMode) Error!void {
        return intToError(c.FT_Render_Glyph(self.handle, @intFromEnum(render_mode)));
    }

    pub fn adjustWeight(self: GlyphSlot, x_delta: i32, y_delta: i32) void {
        return c.FT_GlyphSlot_AdjustWeight(self.handle, x_delta, y_delta);
    }

    pub fn slant(self: GlyphSlot, x_slant: i32, y_slant: i32) void {
        return c.FT_GlyphSlot_Slant(self.handle, x_slant, y_slant);
    }

    pub fn getSubGlyphInfo(self: GlyphSlot, sub_index: u32) Error!SubGlyphInfo {
        var info: SubGlyphInfo = undefined;
        try intToError(c.FT_Get_SubGlyph_Info(self.handle, sub_index, &info.index, &info.flags, &info.arg1, &info.arg2, &info.transform));
        return info;
    }

    pub fn getGlyph(self: GlyphSlot) Error!Glyph {
        var res: c.FT_Glyph = undefined;
        try intToError(c.FT_Get_Glyph(self.handle, &res));
        return Glyph{ .handle = res };
    }
};
pub const Glyph = struct {
    handle: c.FT_Glyph,

    pub fn deinit(self: Glyph) void {
        c.FT_Done_Glyph(self.handle);
    }

    pub fn newGlyph(library: Library, glyph_format: GlyphFormat) Glyph {
        var g: c.FT_Glyph = undefined;
        return .{
            .handle = c.FT_New_Glyph(library.handle, @intFromEnum(glyph_format), &g),
        };
    }

    pub fn copy(self: Glyph) Error!Glyph {
        var g: c.FT_Glyph = undefined;
        try intToError(c.FT_Glyph_Copy(self.handle, &g));
        return Glyph{ .handle = g };
    }

    // pub fn transform(self: Glyph, matrix: ?Matrix, delta: ?Vector) Error!void {
    //     try intToError(c.FT_Glyph_Transform(self.handle, if (matrix) |m| &m else null, if (delta) |d| &d else null));
    // }

    // pub fn getCBox(self: Glyph, bbox_mode: BBoxMode) BBox {
    //     var b: BBox = undefined;
    //     c.FT_Glyph_Get_CBox(self.handle, @intFromEnum(bbox_mode), &b);
    //     return b;
    // }

    pub fn toBitmapGlyph(self: *Glyph, render_mode: RenderMode, origin: ?c.FT_Vector) Error!BitmapGlyph {
        try intToError(c.FT_Glyph_To_Bitmap(&self.handle, @intFromEnum(render_mode), if (origin) |o| &o else null, 1));
        return BitmapGlyph{ .handle = @ptrCast(self.handle) };
    }

    pub fn copyBitmapGlyph(self: *Glyph, render_mode: RenderMode, origin: ?c.FT_Vector) Error!BitmapGlyph {
        try intToError(c.FT_Glyph_To_Bitmap(&self.handle, @intFromEnum(render_mode), if (origin) |o| &o else null, 0));
        return BitmapGlyph{ .handle = @ptrCast(self.handle) };
    }

    // pub fn castBitmapGlyph(self: Glyph) Error!BitmapGlyph {
    //     return BitmapGlyph{ .handle = @ptrCast(self.handle) };
    // }

    // pub fn castOutlineGlyph(self: Glyph) Error!OutlineGlyph {
    //     return OutlineGlyph{ .handle = @ptrCast(self.handle) };
    // }

    // pub fn castSvgGlyph(self: Glyph) Error!SvgGlyph {
    //     return SvgGlyph{ .handle = @ptrCast(self.handle) };
    // }

    // pub fn stroke(self: *Glyph, stroker: Stroker) Error!void {
    //     try intToError(c.FT_Glyph_Stroke(&self.handle, stroker.handle, 0));
    // }

    // pub fn strokeBorder(self: *Glyph, stroker: Stroker, inside: bool) Error!void {
    //     try intToError(c.FT_Glyph_StrokeBorder(&self.handle, stroker.handle, if (inside) 1 else 0, 0));
    // }

    pub fn format(self: Glyph) GlyphFormat {
        return @enumFromInt(self.handle.*.format);
    }

    pub fn advanceX(self: Glyph) isize {
        return self.handle.*.advance.x;
    }

    pub fn advanceY(self: Glyph) isize {
        return self.handle.*.advance.y;
    }
};

pub const GlyphFormat = enum(u32) {
    none = c.FT_GLYPH_FORMAT_NONE,
    composite = c.FT_GLYPH_FORMAT_COMPOSITE,
    bitmap = c.FT_GLYPH_FORMAT_BITMAP,
    outline = c.FT_GLYPH_FORMAT_OUTLINE,
    plotter = c.FT_GLYPH_FORMAT_PLOTTER,
    svg = c.FT_GLYPH_FORMAT_SVG,
};

pub const Bitmap = struct {
    handle: c.FT_Bitmap,

    pub fn init() Bitmap {
        var b: c.FT_Bitmap = undefined;
        c.FT_Bitmap_Init(&b);
        return .{ .handle = b };
    }

    pub fn deinit(self: *Bitmap, lib: Library) void {
        _ = c.FT_Bitmap_Done(lib.handle, &self.handle);
    }

    pub fn copy(self: Bitmap, lib: Library) Error!Bitmap {
        var b: c.FT_Bitmap = undefined;
        try intToError(c.FT_Bitmap_Copy(lib.handle, &self.handle, &b));
        return Bitmap{ .handle = b };
    }

    pub fn embolden(self: *Bitmap, lib: Library, x_strength: i32, y_strength: i32) Error!void {
        try intToError(c.FT_Bitmap_Embolden(lib.handle, &self.handle, x_strength, y_strength));
    }

    pub fn convert(self: Bitmap, lib: Library, alignment: u29) Error!Bitmap {
        var b: c.FT_Bitmap = undefined;
        try intToError(c.FT_Bitmap_Convert(lib.handle, &self.handle, &b, alignment));
        return Bitmap{ .handle = b };
    }

    pub fn blend(self: *Bitmap, lib: Library, source_offset: c.FT_Vector, target_offset: *Vector, color: Color) Error!void {
        var b: c.FT_Bitmap = undefined;
        c.FT_Bitmap_Init(&b);
        try intToError(c.FT_Bitmap_Blend(lib.handle, &self.handle, source_offset, &b, target_offset, color));
    }

    pub fn width(self: Bitmap) u32 {
        return self.handle.width;
    }

    pub fn pitch(self: Bitmap) i32 {
        return self.handle.pitch;
    }

    pub fn rows(self: Bitmap) u32 {
        return self.handle.rows;
    }

    pub fn pixelMode(self: Bitmap) PixelMode {
        return @enumFromInt(self.handle.pixel_mode);
    }

    pub fn buffer(self: Bitmap) ?[]const u8 {
        const buffer_size = @abs(self.pitch()) * self.rows();
        return if (self.handle.buffer == null)
            // freetype returns a null pointer for zero-length allocations
            // https://github.com/hexops-graveyard/freetype/blob/bbd80a52b7b749140ec87d24b6c767c5063be356/freetype/src/base/ftutil.c#L135
            null
        else
            self.handle.buffer[0..buffer_size];
    }
};
pub const BitmapGlyph = struct {
    handle: c.FT_BitmapGlyph,

    pub fn deinit(self: BitmapGlyph) void {
        c.FT_Done_Glyph(@ptrCast(self.handle));
    }

    pub fn left(self: BitmapGlyph) i32 {
        return self.handle.*.left;
    }

    pub fn top(self: BitmapGlyph) i32 {
        return self.handle.*.top;
    }

    pub fn bitmap(self: BitmapGlyph) Bitmap {
        return .{ .handle = self.handle.*.bitmap };
    }
};

pub const PixelMode = enum(u3) {
    none = c.FT_PIXEL_MODE_NONE,
    mono = c.FT_PIXEL_MODE_MONO,
    gray = c.FT_PIXEL_MODE_GRAY,
    gray2 = c.FT_PIXEL_MODE_GRAY2,
    gray4 = c.FT_PIXEL_MODE_GRAY4,
    lcd = c.FT_PIXEL_MODE_LCD,
    lcd_v = c.FT_PIXEL_MODE_LCD_V,
    bgra = c.FT_PIXEL_MODE_BGRA,
};
test "loading memory font" {
    const testing = std.testing;
    const font_data = @import("test.zig").font_regular;

    var lib = try Library.init();
    defer lib.deinit();
    var face = try lib.initMemoryFace(font_data, 0);
    defer face.deinit();

    // Try APIs
    try face.selectCharmap(.unicode);
    try testing.expect(!face.hasFixedSizes());
    try face.setCharSize(12, 0, 0, 0);

    // Try loading
    const idx = face.getCharIndex('A').?;
    try face.loadGlyph(idx, .{});

    // Try getting a truetype table
    const os2 = face.getSfntTable(.os2);
    try testing.expect(os2 != null);
}
