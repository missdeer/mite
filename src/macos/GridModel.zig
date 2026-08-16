//! Converts the shared VT screen into macOS renderer cells.
//!
//! This module deliberately contains no CoreText or Metal code. It is the
//! stable, testable boundary between terminal state and the platform renderer:
//! cell geometry and SGR colors are resolved once, then the macOS renderer can
//! rasterize the resulting frame without reimplementing VT semantics.

const std = @import("std");
const vt = @import("vt");
const TerminalSession = @import("../terminal/Session.zig");

pub const Rgba = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn fromRgb(r: u8, g: u8, b: u8) Rgba {
        return .{ .r = r, .g = g, .b = b };
    }
};

pub const Metrics = struct {
    cell_width: u32,
    cell_height: u32,

    pub fn gridSize(self: Metrics, pixel_width: u32, pixel_height: u32) Size {
        return .{
            .cols = if (self.cell_width == 0) 0 else pixel_width / self.cell_width,
            .rows = if (self.cell_height == 0) 0 else pixel_height / self.cell_height,
        };
    }
};

pub const Size = struct {
    cols: u32,
    rows: u32,
};

pub const Style = struct {
    foreground: Rgba,
    background: Rgba,
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    invisible: bool = false,
    underline: u8 = 0,
    strikethrough: bool = false,
    overline: bool = false,
};

pub const Cell = struct {
    col: u16,
    row: u16,
    width: u8,
    codepoint: u21,
    grapheme: []const u21,
    style: Style,
};

pub const Frame = struct {
    allocator: std.mem.Allocator,
    cells: []Cell,
    cols: u32,
    rows: u32,
    pixel_width: u32,
    pixel_height: u32,
    background: Rgba,

    pub fn deinit(self: *Frame) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }
};

pub const DEFAULT_FOREGROUND = Rgba.fromRgb(0xc8, 0xc4, 0xd0);
pub const DEFAULT_BACKGROUND = Rgba.fromRgb(0x2a, 0x2a, 0x2a);

pub fn build(
    allocator: std.mem.Allocator,
    term: *vt.Terminal,
    metrics: Metrics,
    pixel_width: u32,
    pixel_height: u32,
) !Frame {
    if (metrics.cell_width == 0 or metrics.cell_height == 0) return error.InvalidMetrics;

    const grid = metrics.gridSize(pixel_width, pixel_height);
    const cols = @min(grid.cols, @as(u32, @intCast(term.cols)));
    const rows = @min(grid.rows, @as(u32, @intCast(term.rows)));
    const foreground = if (term.colors.foreground.get()) |color| fromRgb(color) else DEFAULT_FOREGROUND;
    const background = if (term.colors.background.get()) |color| fromRgb(color) else DEFAULT_BACKGROUND;

    var cells: std.ArrayListUnmanaged(Cell) = .empty;
    errdefer cells.deinit(allocator);
    try cells.ensureTotalCapacity(allocator, @as(usize, cols) * rows);

    const screen = term.screens.active;
    var row_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
    var row: u32 = 0;
    while (row_it.next()) |row_pin| {
        if (row >= rows) break;
        const page = row_pin.node.page();
        const page_cells = page.getCells(row_pin.rowAndCell().row);
        var col: u32 = 0;
        var cell_i: usize = 0;
        while (col < cols and cell_i < page_cells.len) {
            const raw = page_cells[cell_i];
            if (raw.wide == .spacer_tail) {
                col += 1;
                cell_i += 1;
                continue;
            }

            const width: u8 = if (raw.wide == .wide and col + 1 < cols) 2 else 1;
            try cells.append(allocator, .{
                .col = @intCast(col),
                .row = @intCast(row),
                .width = width,
                .codepoint = if (raw.content_tag == .codepoint or raw.content_tag == .codepoint_grapheme)
                    (if (raw.content.codepoint.data == 0) ' ' else raw.content.codepoint.data)
                else
                    ' ',
                .grapheme = if (raw.content_tag == .codepoint_grapheme)
                    (page.lookupGrapheme(&page_cells[cell_i]) orelse &.{})
                else
                    &.{},
                .style = styleForCell(raw, page, foreground, background, term),
            });

            col += width;
            cell_i += 1;
        }
        while (col < cols) : (col += 1) {
            try cells.append(allocator, .{
                .col = @intCast(col),
                .row = @intCast(row),
                .width = 1,
                .codepoint = ' ',
                .grapheme = &.{},
                .style = .{ .foreground = foreground, .background = background },
            });
        }
        row += 1;
    }

    while (row < rows) : (row += 1) {
        var col: u32 = 0;
        while (col < cols) : (col += 1) {
            try cells.append(allocator, .{
                .col = @intCast(col),
                .row = @intCast(row),
                .width = 1,
                .codepoint = ' ',
                .grapheme = &.{},
                .style = .{ .foreground = foreground, .background = background },
            });
        }
    }

    return .{
        .allocator = allocator,
        .cells = try cells.toOwnedSlice(allocator),
        .cols = cols,
        .rows = rows,
        .pixel_width = pixel_width,
        .pixel_height = pixel_height,
        .background = background,
    };
}

fn styleForCell(
    cell: anytype,
    page: anytype,
    foreground: Rgba,
    background: Rgba,
    term: *vt.Terminal,
) Style {
    var result = Style{ .foreground = foreground, .background = background };
    if (cell.style_id != 0) {
        const style = page.styles.get(page.memory, cell.style_id).*;
        result.foreground = resolveColor(style.fg_color, &term.colors.palette.current, foreground);
        result.background = resolveColor(style.bg_color, &term.colors.palette.current, background);
        result.bold = style.flags.bold;
        result.italic = style.flags.italic;
        result.faint = style.flags.faint;
        result.invisible = style.flags.invisible;
        result.underline = @intFromEnum(style.flags.underline);
        result.strikethrough = style.flags.strikethrough;
        result.overline = style.flags.overline;
        if (style.flags.inverse) {
            const swap = result.foreground;
            result.foreground = result.background;
            result.background = swap;
        }
    }

    switch (cell.content_tag) {
        .bg_color_palette => result.background = fromRgb(term.colors.palette.current[cell.content.color_palette.data]),
        .bg_color_rgb => result.background = fromRgb(cell.content.color_rgb),
        else => {},
    }
    if (result.faint) {
        result.foreground.r /= 2;
        result.foreground.g /= 2;
        result.foreground.b /= 2;
    }
    if (result.invisible) result.foreground = result.background;
    return result;
}

fn resolveColor(color: vt.Style.Color, palette: anytype, fallback: Rgba) Rgba {
    return switch (color) {
        .none => fallback,
        .palette => |index| fromRgb(palette[index]),
        .rgb => |rgb| fromRgb(rgb),
    };
}

fn fromRgb(rgb: anytype) Rgba {
    return .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
}

test "grid model preserves ordinary, wide, and styled VT cells" {
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

    session.feed("A界\x1b[1;3;4;38;2;10;20;30;48;2;40;50;60mB");
    var frame = try build(std.testing.allocator, session.term, .{ .cell_width = 9, .cell_height = 18 }, 72, 36);
    defer frame.deinit();

    var found_wide = false;
    var found_styled = false;
    for (frame.cells) |cell| {
        if (cell.codepoint == '界') {
            found_wide = true;
            try std.testing.expectEqual(@as(u8, 2), cell.width);
            try std.testing.expectEqual(@as(u16, 1), cell.col);
        }
        if (cell.codepoint == 'B') {
            found_styled = true;
            try std.testing.expect(cell.style.bold);
            try std.testing.expect(cell.style.italic);
            try std.testing.expectEqual(@as(u8, 1), cell.style.underline);
            try std.testing.expectEqual(Rgba.fromRgb(10, 20, 30), cell.style.foreground);
            try std.testing.expectEqual(Rgba.fromRgb(40, 50, 60), cell.style.background);
        }
    }
    try std.testing.expect(found_wide);
    try std.testing.expect(found_styled);
}

test "grid model recomputes visible grid after a pixel resize" {
    var session: TerminalSession = undefined;
    var context: u8 = 0;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .hooks = .{ .context = &context },
    });
    defer session.deinit();

    var frame = try build(std.testing.allocator, session.term, .{ .cell_width = 9, .cell_height = 18 }, 27, 36);
    defer frame.deinit();
    try std.testing.expectEqual(@as(u32, 3), frame.cols);
    try std.testing.expectEqual(@as(u32, 2), frame.rows);
    try std.testing.expectEqual(@as(usize, 6), frame.cells.len);
}
