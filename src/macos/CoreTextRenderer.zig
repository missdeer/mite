const CoreTextRenderer = @This();

const builtin = @import("builtin");
const std = @import("std");
const macos = @import("Apple.zig");

const GridModel = @import("GridModel.zig");
const MetalBackend = @import("MetalBackend.zig");
const TerminalSession = @import("../terminal/Session.zig");

comptime {
    if (builtin.os.tag != .macos) @compileError("CoreTextRenderer is macOS-only");
}

const graphics = macos.graphics;
const text = macos.text;
const foundation = macos.foundation;

pub const Options = struct {
    allocator: std.mem.Allocator,
    family: []const u8 = "Menlo",
    font_size: f32 = 14,
    scale: f32 = 1,
    pixel_width: u32,
    pixel_height: u32,
};

pub const RenderResult = struct {
    cols: u32,
    rows: u32,
    texture: *anyopaque,
};

/// Grid position (viewport-relative) of the block cursor to draw as inverse
/// video. Rendering the cursor here keeps it pixel-aligned with the glyphs.
pub const Cursor = struct {
    col: u16,
    row: u16,
};

const FontSet = struct {
    regular: *text.Font,
    bold: *text.Font,
    italic: *text.Font,
    bold_italic: *text.Font,

    fn init(family: []const u8, size: f32) !FontSet {
        const name = try foundation.String.createWithBytes(family, .utf8, false);
        defer name.release();
        const descriptor = try text.FontDescriptor.createWithNameAndSize(name, size);
        defer descriptor.release();
        const regular = try text.Font.createWithFontDescriptor(descriptor, size);
        errdefer regular.release();
        const bold = copyWithTraits(regular, true, false);
        errdefer bold.release();
        const italic = copyWithTraits(regular, false, true);
        errdefer italic.release();
        const bold_italic = copyWithTraits(regular, true, true);
        errdefer bold_italic.release();
        return .{
            .regular = regular,
            .bold = bold,
            .italic = italic,
            .bold_italic = bold_italic,
        };
    }

    fn deinit(self: *FontSet) void {
        self.bold_italic.release();
        self.italic.release();
        self.bold.release();
        self.regular.release();
        self.* = undefined;
    }

    fn select(self: *const FontSet, style: GridModel.Style) *text.Font {
        if (style.bold and style.italic) return self.bold_italic;
        if (style.bold) return self.bold;
        if (style.italic) return self.italic;
        return self.regular;
    }
};

allocator: std.mem.Allocator,
family: []u8,
font_size: f32,
scale: f32,
fonts: FontSet,
metrics: GridModel.Metrics,
pixel_width: u32,
pixel_height: u32,
pixels: []u8,
metal: MetalBackend,

pub fn init(options: Options) !CoreTextRenderer {
    if (options.font_size <= 0 or options.scale <= 0) return error.InvalidFontSize;
    if (options.pixel_width == 0 or options.pixel_height == 0) return error.InvalidDrawableSize;

    const family = try options.allocator.dupe(u8, options.family);
    errdefer options.allocator.free(family);
    var fonts = try FontSet.init(family, options.font_size * options.scale);
    errdefer fonts.deinit();
    const metrics = try metricsForFont(fonts.regular);
    var metal = try MetalBackend.init();
    errdefer metal.deinit();
    try metal.resize(options.pixel_width, options.pixel_height);

    const pixel_count = try pixelBufferLength(options.pixel_width, options.pixel_height);
    const pixels = try options.allocator.alloc(u8, pixel_count);
    errdefer options.allocator.free(pixels);

    return .{
        .allocator = options.allocator,
        .family = family,
        .font_size = options.font_size,
        .scale = options.scale,
        .fonts = fonts,
        .metrics = metrics,
        .pixel_width = options.pixel_width,
        .pixel_height = options.pixel_height,
        .pixels = pixels,
        .metal = metal,
    };
}

pub fn deinit(self: *CoreTextRenderer) void {
    self.metal.deinit();
    self.allocator.free(self.pixels);
    self.fonts.deinit();
    self.allocator.free(self.family);
    self.* = undefined;
}

pub fn resize(self: *CoreTextRenderer, pixel_width: u32, pixel_height: u32, scale: f32) !void {
    if (pixel_width == 0 or pixel_height == 0) return error.InvalidDrawableSize;
    if (scale <= 0) return error.InvalidFontSize;
    if (self.pixel_width == pixel_width and self.pixel_height == pixel_height and self.scale == scale) return;

    var replacement_fonts: ?FontSet = null;
    var replacement_metrics = self.metrics;
    if (self.scale != scale) {
        replacement_fonts = try FontSet.init(self.family, self.font_size * scale);
        errdefer if (replacement_fonts) |*fonts| fonts.deinit();
        replacement_metrics = try metricsForFont(replacement_fonts.?.regular);
    }

    const replacement = try self.allocator.alloc(u8, try pixelBufferLength(pixel_width, pixel_height));
    errdefer self.allocator.free(replacement);
    try self.metal.resize(pixel_width, pixel_height);

    self.allocator.free(self.pixels);
    self.pixels = replacement;
    if (replacement_fonts) |fonts| {
        self.fonts.deinit();
        self.fonts = fonts;
    }
    self.metrics = replacement_metrics;
    self.scale = scale;
    self.pixel_width = pixel_width;
    self.pixel_height = pixel_height;
}

/// Drawable height minus the reserved bottom gutter. Rows are laid out from the
/// top of the drawable, so holding back one cell row keeps the last text row
/// clear of the window's rounded bottom corners, which otherwise clip the
/// leading glyph of that row.
pub fn contentHeight(self: *const CoreTextRenderer) u32 {
    return self.pixel_height -| self.metrics.cell_height;
}

pub fn gridSize(self: *const CoreTextRenderer) GridModel.Size {
    return self.metrics.gridSize(self.pixel_width, self.contentHeight());
}

pub fn render(self: *CoreTextRenderer, session: *TerminalSession, cursor: ?Cursor) !RenderResult {
    session.syncPixelSize(self.metrics.cell_width, self.metrics.cell_height);
    var frame = try GridModel.build(
        self.allocator,
        session.term,
        self.metrics,
        self.pixel_width,
        self.contentHeight(),
    );
    defer frame.deinit();

    try self.rasterize(&frame, cursor);
    try self.metal.render(self.pixels);
    return .{
        .cols = frame.cols,
        .rows = frame.rows,
        .texture = self.metal.texture() orelse return error.DrawableNotConfigured,
    };
}

fn rasterize(self: *CoreTextRenderer, frame: *const GridModel.Frame, cursor: ?Cursor) !void {
    const color_space = try graphics.ColorSpace.createDeviceRGB();
    defer color_space.release();
    const bitmap_info = @intFromEnum(graphics.BitmapInfo.byte_order_32_little) |
        @intFromEnum(graphics.ImageAlphaInfo.premultiplied_first);
    const context = try graphics.BitmapContext.create(
        self.pixels,
        self.pixel_width,
        self.pixel_height,
        8,
        @as(usize, self.pixel_width) * 4,
        color_space,
        bitmap_info,
    );
    defer graphics.BitmapContext.context.release(context);

    const ctx = graphics.BitmapContext.context;
    ctx.setAllowsAntialiasing(context, true);
    ctx.setShouldAntialias(context, true);
    ctx.setShouldSmoothFonts(context, true);
    ctx.setTextDrawingMode(context, .fill);
    ctx.setTextMatrix(context, graphics.AffineTransform.identity());
    setFill(context, frame.background);
    ctx.fillRect(context, graphics.Rect.init(0, 0, self.pixel_width, self.pixel_height));

    for (frame.cells) |cell| {
        var draw_cell = cell;
        // The cursor cell is drawn as inverse video (swapped fg/bg), which keeps
        // the block perfectly aligned with the glyph grid.
        if (cursor) |cur| {
            if (cell.col == cur.col and cell.row == cur.row) {
                draw_cell.style.foreground = cell.style.background;
                draw_cell.style.background = cell.style.foreground;
            }
        }

        const x = @as(f64, @floatFromInt(@as(u32, draw_cell.col) * self.metrics.cell_width));
        const y = @as(f64, @floatFromInt(self.pixel_height - (@as(u32, draw_cell.row) + 1) * self.metrics.cell_height));
        const width = @as(f64, @floatFromInt(@as(u32, draw_cell.width) * self.metrics.cell_width));
        const height = @as(f64, @floatFromInt(self.metrics.cell_height));
        setFill(context, draw_cell.style.background);
        ctx.fillRect(context, graphics.Rect.init(x, y, width, height));
        if (draw_cell.style.invisible) continue;

        const font = self.fonts.select(draw_cell.style);
        try drawCellText(context, font, draw_cell, x, y, width, self.metrics.cell_height);
    }
}

fn drawCellText(
    context: *graphics.BitmapContext,
    base_font: *text.Font,
    cell: GridModel.Cell,
    x: f64,
    y: f64,
    cell_width: f64,
    cell_height: u32,
) !void {
    var characters: [32]u16 = undefined;
    var character_len: usize = 0;
    try appendCodepoint(&characters, &character_len, cell.codepoint);
    for (cell.grapheme) |codepoint| {
        if (character_len + 2 > characters.len) break;
        try appendCodepoint(&characters, &character_len, codepoint);
    }

    var fallback: ?*text.Font = null;
    var font = base_font;
    var glyphs: [32]graphics.Glyph = @splat(0);
    if (!font.getGlyphsForCharacters(characters[0..character_len], glyphs[0..character_len])) {
        const string = try foundation.String.createWithCharacters(characters[0..character_len]);
        defer string.release();
        fallback = font.createForString(string, foundation.Range.init(0, character_len));
        if (fallback) |resolved| {
            font = resolved;
            _ = font.getGlyphsForCharacters(characters[0..character_len], glyphs[0..character_len]);
        }
    }
    defer if (fallback) |resolved| resolved.release();

    var advances: [32]graphics.Size = undefined;
    const total_advance = font.getAdvancesForGlyphs(
        .horizontal,
        glyphs[0..character_len],
        advances[0..character_len],
    );
    const ascent = font.getAscent();
    const descent = font.getDescent();
    const content_height = ascent + descent;
    // `y` is the cell's bottom edge in the bottom-left-origin CoreGraphics
    // context, so the baseline sits `descent` above it (plus half the leading to
    // center). Using ascent here would push glyphs up out of their cell.
    const baseline = y + descent + @max(0, (@as(f64, @floatFromInt(cell_height)) - content_height) / 2);
    var pen_x = x + @max(0, (cell_width - total_advance) / 2);
    var positions: [32]graphics.Point = undefined;
    for (positions[0..character_len], advances[0..character_len]) |*position, advance| {
        position.* = .{ .x = pen_x, .y = baseline };
        pen_x += advance.width;
    }

    setFill(context, cell.style.foreground);
    font.drawGlyphs(glyphs[0..character_len], positions[0..character_len], context);
    drawDecorations(context, font, cell.style, x, baseline, cell_width);
}

fn drawDecorations(
    context: *graphics.BitmapContext,
    font: *text.Font,
    style: GridModel.Style,
    x: f64,
    baseline: f64,
    width: f64,
) void {
    const ctx = graphics.BitmapContext.context;
    const thickness = @max(1, font.getUnderlineThickness());
    setFill(context, style.foreground);
    if (style.underline != 0) {
        ctx.fillRect(context, graphics.Rect.init(x, baseline + font.getUnderlinePosition(), width, thickness));
    }
    if (style.strikethrough) {
        ctx.fillRect(context, graphics.Rect.init(x, baseline + font.getXHeight() / 2, width, thickness));
    }
    if (style.overline) {
        ctx.fillRect(context, graphics.Rect.init(x, baseline + font.getAscent() - thickness, width, thickness));
    }
}

fn setFill(context: *graphics.BitmapContext, color: GridModel.Rgba) void {
    graphics.BitmapContext.context.setRGBFillColor(
        context,
        @as(f64, @floatFromInt(color.r)) / 255,
        @as(f64, @floatFromInt(color.g)) / 255,
        @as(f64, @floatFromInt(color.b)) / 255,
        @as(f64, @floatFromInt(color.a)) / 255,
    );
}

fn copyWithTraits(base: *text.Font, bold: bool, italic: bool) *text.Font {
    const traits = text.FontSymbolicTraits{ .bold = bold, .italic = italic };
    if (base.copyWithSymbolicTraits(traits)) |font| return font;
    base.retain();
    return base;
}

fn metricsForFont(font: *text.Font) !GridModel.Metrics {
    var glyph: [1]graphics.Glyph = .{0};
    if (!font.getGlyphsForCharacters(&[_]u16{'M'}, &glyph)) return error.FontHasNoCellGlyph;
    var advance: [1]graphics.Size = undefined;
    _ = font.getAdvancesForGlyphs(.horizontal, &glyph, &advance);
    const width = @max(1, @as(u32, @intFromFloat(@ceil(advance[0].width))));
    const height_value = font.getAscent() + font.getDescent() + font.getLeading();
    const height = @max(1, @as(u32, @intFromFloat(@ceil(height_value))));
    return .{ .cell_width = width, .cell_height = height };
}

fn appendCodepoint(buffer: []u16, len: *usize, codepoint: u21) !void {
    if (codepoint <= 0xffff) {
        if (len.* == buffer.len) return error.GraphemeTooLong;
        buffer[len.*] = @intCast(codepoint);
        len.* += 1;
        return;
    }
    if (len.* + 2 > buffer.len) return error.GraphemeTooLong;
    const value = @as(u32, codepoint) - 0x10000;
    buffer[len.*] = @intCast(0xd800 + (value >> 10));
    buffer[len.* + 1] = @intCast(0xdc00 + (value & 0x3ff));
    len.* += 2;
}

fn pixelBufferLength(width: u32, height: u32) !usize {
    const pixels = std.math.mul(usize, width, height) catch return error.InvalidDrawableSize;
    return std.math.mul(usize, pixels, 4) catch return error.InvalidDrawableSize;
}

test "CoreText resolves ordinary and wide glyphs" {
    var fonts = try FontSet.init("Menlo", 14);
    defer fonts.deinit();
    var ordinary_glyph: [1]graphics.Glyph = .{0};
    try std.testing.expect(fonts.regular.getGlyphsForCharacters(&[_]u16{'A'}, &ordinary_glyph));
    try std.testing.expect(ordinary_glyph[0] != 0);

    const wide_characters = [_]u16{'界'};
    const wide_string = try foundation.String.createWithCharacters(&wide_characters);
    defer wide_string.release();
    const wide_font = fonts.regular.createForString(wide_string, foundation.Range.init(0, 1)) orelse
        return error.FontHasNoWideGlyphFallback;
    defer wide_font.release();
    var wide_glyph: [1]graphics.Glyph = .{0};
    try std.testing.expect(wide_font.getGlyphsForCharacters(&wide_characters, &wide_glyph));
    try std.testing.expect(wide_glyph[0] != 0);
    const metrics = try metricsForFont(fonts.regular);
    try std.testing.expect(metrics.cell_width > 0);
    try std.testing.expect(metrics.cell_height > 0);
}

test "CoreText and Metal render a resized styled terminal frame" {
    var session: TerminalSession = undefined;
    var context: u8 = 0;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 8,
        .rows = 2,
        .hooks = .{ .context = &context },
    });
    defer session.deinit();
    session.feed("A界\x1b[1;3;4;31;44mB");

    var renderer = try CoreTextRenderer.init(.{
        .allocator = std.testing.allocator,
        .pixel_width = 320,
        .pixel_height = 96,
    });
    defer renderer.deinit();
    try renderer.resize(360, 108, 1);

    // The grid must stop a full cell short of the drawable's bottom edge, so the
    // window's rounded corners never clip the last row's leading glyph.
    const grid = renderer.gridSize();
    try std.testing.expect(grid.rows > 0);
    try std.testing.expect(
        renderer.pixel_height - grid.rows * renderer.metrics.cell_height >= renderer.metrics.cell_height,
    );

    const result = try renderer.render(&session, .{ .col = 0, .row = 0 });
    try std.testing.expect(result.cols > 0);
    try std.testing.expect(result.rows > 0);
    try std.testing.expect(@intFromPtr(result.texture) != 0);
}
