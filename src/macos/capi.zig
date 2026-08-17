//! C-ABI boundary over the macOS PTY session and CoreText/Metal renderer.
//!
//! The Swift/AppKit application drives the terminal exclusively through these
//! exported functions; it never sees Zig or VT internals. Every function that
//! touches VT state (`feed`, `render`, `resize`, mode/scroll/selection queries)
//! must be called from the main thread — this preserves the single-threaded VT
//! invariant the core relies on. Only `mostty_tab_read` is safe off the main
//! thread: it is a bare `read(2)` on the PTY master and never touches VT state.

const builtin = @import("builtin");
const std = @import("std");
const vt = @import("vt");

const PtySession = @import("PtySession.zig");
const CoreTextRenderer = @import("CoreTextRenderer.zig");
const GridModel = @import("GridModel.zig");
const title_mod = @import("../terminal/title.zig");

comptime {
    if (builtin.os.tag != .macos) @compileError("capi is macOS-only");
}

const allocator = std.heap.c_allocator;

fn runtimeIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Tab = struct {
    pty: PtySession,
    renderer: CoreTextRenderer,
    exit_code: ?i32 = null,
};

/// Create a terminal tab sized to fit `pixel_width` x `pixel_height` at
/// `scale`. The initial grid is derived from the renderer's cell metrics so the
/// PTY, VT, and renderer agree on dimensions from the first frame. Returns null
/// on any failure (renderer, Metal, or shell spawn).
export fn mostty_tab_create(
    pixel_width: u32,
    pixel_height: u32,
    scale: f32,
    font_size: f32,
) ?*Tab {
    return createTab(pixel_width, pixel_height, scale, font_size) catch null;
}

// Split out so `errdefer` runs on failure: the exported wrapper returns an
// optional, and `return null` is a normal (not error) return, which would skip
// any errdefer cleanup and leak the Tab plus its renderer resources.
fn createTab(pixel_width: u32, pixel_height: u32, scale: f32, font_size: f32) !*Tab {
    const tab = try allocator.create(Tab);
    errdefer allocator.destroy(tab);

    tab.renderer = try CoreTextRenderer.init(.{
        .allocator = allocator,
        .font_size = if (font_size > 0) font_size else 14,
        .scale = if (scale > 0) scale else 1,
        .pixel_width = pixel_width,
        .pixel_height = pixel_height,
    });
    errdefer tab.renderer.deinit();

    const grid = tab.renderer.gridSize();
    if (grid.cols == 0 or grid.rows == 0) return error.EmptyGrid;

    try tab.pty.init(.{
        .io = runtimeIo(),
        .terminal_allocator = allocator,
        .stream_allocator = allocator,
        .cols = @intCast(grid.cols),
        .rows = @intCast(grid.rows),
    });
    tab.exit_code = null;
    return tab;
}

export fn mostty_tab_destroy(tab_opt: ?*Tab) void {
    const tab = tab_opt orelse return;
    tab.pty.deinit();
    tab.renderer.deinit();
    allocator.destroy(tab);
}

/// The Metal device the renderer draws with. The on-screen layer must adopt
/// this device so it can present the renderer's target texture.
export fn mostty_tab_metal_device(tab_opt: ?*Tab) ?*anyopaque {
    const tab = tab_opt orelse return null;
    return tab.renderer.metal.device.value;
}

/// Bare read from the PTY master, waiting up to ~50ms for data. Safe to call
/// off the main thread; never touches VT state. Returns the byte count (>0), 0
/// on EOF/hangup, -1 on error, or -2 on timeout (the caller should re-check its
/// stop flag and call again). The timeout lets a background reader shut down
/// promptly without relying on close() to interrupt a blocked read.
export fn mostty_tab_read(tab_opt: ?*Tab, buf: [*]u8, cap: usize) isize {
    const tab = tab_opt orelse return -1;
    const fd = tab.pty.master_fd;
    if (fd < 0) return 0;

    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, 50) catch return -1;
    if (ready == 0) return -2;
    if (fds[0].revents & std.posix.POLL.IN == 0) {
        // No data pending; a hangup/error means EOF.
        return 0;
    }
    const count = std.posix.read(fd, buf[0..cap]) catch |err| switch (err) {
        error.WouldBlock => return -2,
        error.InputOutput => return 0,
        else => return -1,
    };
    if (count == 0) return 0;
    return @intCast(count);
}

/// Feed PTY bytes into the VT state machine. Main thread only.
export fn mostty_tab_feed(tab_opt: ?*Tab, ptr: [*]const u8, len: usize) void {
    const tab = tab_opt orelse return;
    tab.pty.terminal.feed(ptr[0..len]);
}

/// Write input bytes to the PTY master.
export fn mostty_tab_write(tab_opt: ?*Tab, ptr: [*]const u8, len: usize) void {
    const tab = tab_opt orelse return;
    tab.pty.write(ptr[0..len]) catch {};
}

/// Resize the drawable and propagate the new grid to PTY + VT. Writes the
/// resulting grid dimensions to `out_cols`/`out_rows`. Returns false on failure.
export fn mostty_tab_set_surface(
    tab_opt: ?*Tab,
    pixel_width: u32,
    pixel_height: u32,
    scale: f32,
    out_cols: *u32,
    out_rows: *u32,
) bool {
    const tab = tab_opt orelse return false;
    tab.renderer.resize(pixel_width, pixel_height, if (scale > 0) scale else 1) catch return false;
    const grid = tab.renderer.gridSize();
    if (grid.cols == 0 or grid.rows == 0) return false;
    tab.pty.resize(@intCast(grid.cols), @intCast(grid.rows)) catch return false;
    out_cols.* = grid.cols;
    out_rows.* = grid.rows;
    return true;
}

/// Render the current terminal state and return the presentable Metal texture
/// (the renderer's target). Writes the rendered grid size to out params. When
/// `cursor_on` is set the block cursor is drawn, provided DECTCEM is enabled and
/// the viewport is at the bottom (host drives blink by toggling `cursor_on`).
export fn mostty_tab_render(tab_opt: ?*Tab, cursor_on: bool, out_cols: *u32, out_rows: *u32) ?*anyopaque {
    const tab = tab_opt orelse return null;
    const term = tab.pty.terminal.term;
    const screen = term.screens.active;

    // The cursor's authoritative position is its page pin. Convert it into
    // VIEWPORT coordinates — the same space GridModel iterates — so the drawn
    // block lines up with the glyph grid. `cursor.x`/`cursor.y` are active-area
    // coordinates, which differ from the viewport when scrollback is present.
    // A null result means the cursor is scrolled out of view.
    var cursor_cell: ?CoreTextRenderer.Cursor = null;
    if (cursor_on and term.modes.get(.cursor_visible) and screen.viewportIsBottom()) {
        if (screen.pages.pointFromPin(.viewport, screen.cursor.page_pin.*)) |pt| {
            cursor_cell = .{
                .col = @intCast(pt.viewport.x),
                .row = @intCast(pt.viewport.y),
            };
        }
    }

    const result = tab.renderer.render(&tab.pty.terminal, cursor_cell) catch return null;
    out_cols.* = result.cols;
    out_rows.* = result.rows;
    return result.texture;
}

/// Copy the tab's display title as UTF-8 into `buf`. The shell-provided title is
/// reduced to its final path component when it looks like a path (mirroring the
/// Windows tab bar); the full title stays canonical in the terminal. Returns the
/// byte count written (never exceeding `cap`), or 0 when there is no title or the
/// reduction is empty (root / trailing separator) — the caller then keeps the
/// previous label rather than blanking the tab.
export fn mostty_tab_title(tab_opt: ?*Tab, buf: [*]u8, cap: usize) usize {
    const tab = tab_opt orelse return 0;
    const title = tab.pty.terminal.term.getTitle() orelse return 0;
    const shown = title_mod.displayTitle(title);
    if (shown.len == 0) return 0;
    const n = @min(shown.len, cap);
    @memcpy(buf[0..n], shown[0..n]);
    return n;
}

/// Poll whether the child process has exited. Returns true once it has, writing
/// the exit status to `out_code` (negative values are `-signal`).
export fn mostty_tab_poll_exit(tab_opt: ?*Tab, out_code: *i32) bool {
    const tab = tab_opt orelse return false;
    if (tab.exit_code) |code| {
        out_code.* = code;
        return true;
    }
    const exit = tab.pty.tryWait() catch {
        // Child already reaped or wait failed: treat as exited.
        tab.exit_code = 0;
        out_code.* = 0;
        return true;
    };
    const result = exit orelse return false;
    const code: i32 = switch (result) {
        .exited => |v| v,
        .signaled => |sig| -@as(i32, @intCast(@intFromEnum(sig) & 0x7fff_ffff)),
        .stopped => return false,
        .unknown => -1,
    };
    tab.exit_code = code;
    out_code.* = code;
    return true;
}

/// Cell metrics in device pixels, so the host can map mouse points to grid
/// cells and translate wheel deltas to rows.
export fn mostty_tab_cell_size(tab_opt: ?*Tab, out_w: *u32, out_h: *u32) void {
    const tab = tab_opt orelse return;
    out_w.* = tab.renderer.metrics.cell_width;
    out_h.* = tab.renderer.metrics.cell_height;
}

/// Cursor position in grid cells (column, row from the top of the viewport),
/// used to anchor the IME composition overlay and candidate window.
export fn mostty_tab_cursor(tab_opt: ?*Tab, out_col: *u32, out_row: *u32) void {
    const tab = tab_opt orelse return;
    // Convert the cursor's page pin into VIEWPORT coordinates, matching
    // mostty_tab_render, so the IME anchor and overlay cursor line up with the
    // glyph grid even when scrollback is present. Falls back to the origin when
    // the cursor is scrolled out of view.
    const screen = tab.pty.terminal.term.screens.active;
    if (screen.pages.pointFromPin(.viewport, screen.cursor.page_pin.*)) |pt| {
        out_col.* = @intCast(pt.viewport.x);
        out_row.* = @intCast(pt.viewport.y);
    } else {
        out_col.* = 0;
        out_row.* = 0;
    }
}

export fn mostty_tab_app_cursor_keys(tab_opt: ?*Tab) bool {
    const tab = tab_opt orelse return false;
    return tab.pty.terminal.term.modes.get(.cursor_keys);
}

export fn mostty_tab_app_keypad(tab_opt: ?*Tab) bool {
    const tab = tab_opt orelse return false;
    return tab.pty.terminal.term.modes.get(.keypad_keys);
}

export fn mostty_tab_bracketed_paste(tab_opt: ?*Tab) bool {
    const tab = tab_opt orelse return false;
    return tab.pty.terminal.term.modes.get(.bracketed_paste);
}

/// DECTCEM: whether the text cursor should be shown.
export fn mostty_tab_cursor_visible(tab_opt: ?*Tab) bool {
    const tab = tab_opt orelse return true;
    return tab.pty.terminal.term.modes.get(.cursor_visible);
}

/// Scroll the viewport by `delta_rows` (negative scrolls up into history,
/// positive scrolls down toward the active area).
export fn mostty_tab_scroll(tab_opt: ?*Tab, delta_rows: i32) void {
    const tab = tab_opt orelse return;
    tab.pty.terminal.term.scrollViewport(.{ .delta = @as(isize, delta_rows) });
}

export fn mostty_tab_scroll_to_bottom(tab_opt: ?*Tab) void {
    const tab = tab_opt orelse return;
    tab.pty.terminal.term.scrollViewport(.{ .bottom = {} });
}

/// True when the viewport is pinned to the bottom (follow mode active).
export fn mostty_tab_at_bottom(tab_opt: ?*Tab) bool {
    const tab = tab_opt orelse return true;
    return tab.pty.terminal.term.screens.active.viewportIsBottom();
}

/// Extract the text of a linear selection [start .. end] over the current
/// viewport as UTF-8 into `buf`. Rows between the endpoints are taken in full;
/// trailing blank cells on each row are trimmed and rows joined with newlines.
export fn mostty_tab_selection_text(
    tab_opt: ?*Tab,
    start_col: u32,
    start_row: u32,
    end_col: u32,
    end_row: u32,
    buf: [*]u8,
    cap: usize,
) usize {
    const tab = tab_opt orelse return 0;
    var r0 = start_row;
    var c0 = start_col;
    var r1 = end_row;
    var c1 = end_col;
    if (r1 < r0 or (r1 == r0 and c1 < c0)) {
        std.mem.swap(u32, &r0, &r1);
        std.mem.swap(u32, &c0, &c1);
    }

    var frame = GridModel.build(
        allocator,
        tab.pty.terminal.term,
        tab.renderer.metrics,
        tab.renderer.pixel_width,
        tab.renderer.pixel_height,
    ) catch return 0;
    defer frame.deinit();

    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);

    var row: u32 = r0;
    while (row <= r1) : (row += 1) {
        const line_start: u32 = if (row == r0) c0 else 0;
        const line_end: u32 = if (row == r1) c1 else frame.cols;
        var line = std.ArrayListUnmanaged(u8).empty;
        defer line.deinit(allocator);
        for (frame.cells) |cell| {
            if (cell.row != row) continue;
            if (cell.col < line_start or cell.col > line_end) continue;
            appendCell(&line, cell) catch return 0;
        }
        trimTrailingSpaces(&line);
        if (row != r0) out.append(allocator, '\n') catch return 0;
        out.appendSlice(allocator, line.items) catch return 0;
    }

    const n = @min(out.items.len, cap);
    @memcpy(buf[0..n], out.items[0..n]);
    return n;
}

fn appendCell(line: *std.ArrayListUnmanaged(u8), cell: GridModel.Cell) !void {
    try appendCodepoint(line, cell.codepoint);
    for (cell.grapheme) |cp| try appendCodepoint(line, cp);
}

fn appendCodepoint(line: *std.ArrayListUnmanaged(u8), codepoint: u21) !void {
    var utf8: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(codepoint, &utf8) catch return;
    try line.appendSlice(allocator, utf8[0..len]);
}

fn trimTrailingSpaces(line: *std.ArrayListUnmanaged(u8)) void {
    while (line.items.len > 0 and line.items[line.items.len - 1] == ' ') {
        _ = line.pop();
    }
}

// -- Keyboard encoding -------------------------------------------------------
//
// The host maps NSEvent special keys to `Key` and passes a modifier bitmask;
// this pure function emits the xterm-compatible byte sequence, honoring the
// active cursor-key mode. Keeping it here makes the trickiest encoding testable
// without an AppKit event loop.

pub const Key = enum(u32) {
    up = 0,
    down = 1,
    right = 2,
    left = 3,
    home = 4,
    end = 5,
    page_up = 6,
    page_down = 7,
    insert = 8,
    delete = 9,
    enter = 10,
    tab = 11,
    backspace = 12,
    escape = 13,
    f1 = 14,
    f2 = 15,
    f3 = 16,
    f4 = 17,
    f5 = 18,
    f6 = 19,
    f7 = 20,
    f8 = 21,
    f9 = 22,
    f10 = 23,
    f11 = 24,
    f12 = 25,
    _,
};

pub const mod_shift: u32 = 1;
pub const mod_alt: u32 = 2;
pub const mod_ctrl: u32 = 4;

/// xterm modifier parameter: 1 + shift + 2*alt + 4*ctrl. Returns 1 when no
/// modifiers are active (meaning "omit the modifier").
fn xtermModifier(mods: u32) u8 {
    var value: u8 = 1;
    if (mods & mod_shift != 0) value += 1;
    if (mods & mod_alt != 0) value += 2;
    if (mods & mod_ctrl != 0) value += 4;
    return value;
}

/// Encode a special key into `buf`, returning the byte count. `app_cursor`
/// selects DECCKM application cursor-key sequences for the arrows/home/end.
export fn mostty_encode_key(key: u32, mods: u32, app_cursor: bool, buf: [*]u8, cap: usize) usize {
    var stack: [16]u8 = undefined;
    const seq = encodeKey(@enumFromInt(key), mods, app_cursor, &stack);
    const n = @min(seq.len, cap);
    @memcpy(buf[0..n], seq[0..n]);
    return n;
}

fn encodeKey(key: Key, mods: u32, app_cursor: bool, stack: *[16]u8) []const u8 {
    const m = xtermModifier(mods);
    return switch (key) {
        .up => cursor(stack, 'A', m, app_cursor),
        .down => cursor(stack, 'B', m, app_cursor),
        .right => cursor(stack, 'C', m, app_cursor),
        .left => cursor(stack, 'D', m, app_cursor),
        .home => cursor(stack, 'H', m, app_cursor),
        .end => cursor(stack, 'F', m, app_cursor),
        .insert => tilde(stack, 2, m),
        .delete => tilde(stack, 3, m),
        .page_up => tilde(stack, 5, m),
        .page_down => tilde(stack, 6, m),
        .f1 => func(stack, 'P', m),
        .f2 => func(stack, 'Q', m),
        .f3 => func(stack, 'R', m),
        .f4 => func(stack, 'S', m),
        .f5 => tilde(stack, 15, m),
        .f6 => tilde(stack, 17, m),
        .f7 => tilde(stack, 18, m),
        .f8 => tilde(stack, 19, m),
        .f9 => tilde(stack, 20, m),
        .f10 => tilde(stack, 21, m),
        .f11 => tilde(stack, 23, m),
        .f12 => tilde(stack, 24, m),
        .enter => "\r",
        .tab => if (mods & mod_shift != 0) "\x1b[Z" else "\t",
        .backspace => "\x7f",
        .escape => "\x1b",
        _ => "",
    };
}

/// Arrow / home / end keys. Application mode (no modifiers) uses SS3 (ESC O x);
/// with modifiers or in normal mode, CSI is used, adding `1;m` when modified.
fn cursor(stack: *[16]u8, final: u8, m: u8, app_cursor: bool) []const u8 {
    if (m == 1) {
        if (app_cursor) {
            stack[0] = 0x1b;
            stack[1] = 'O';
            stack[2] = final;
            return stack[0..3];
        }
        stack[0] = 0x1b;
        stack[1] = '[';
        stack[2] = final;
        return stack[0..3];
    }
    return std.fmt.bufPrint(stack, "\x1b[1;{d}{c}", .{ m, final }) catch stack[0..0];
}

/// CSI `n ~` keys (insert/delete/page/F5+), adding `;m` when modified.
fn tilde(stack: *[16]u8, n: u8, m: u8) []const u8 {
    if (m == 1) return std.fmt.bufPrint(stack, "\x1b[{d}~", .{n}) catch stack[0..0];
    return std.fmt.bufPrint(stack, "\x1b[{d};{d}~", .{ n, m }) catch stack[0..0];
}

/// F1-F4: SS3 (ESC O x) when unmodified, CSI `1;m x` when modified.
fn func(stack: *[16]u8, final: u8, m: u8) []const u8 {
    if (m == 1) {
        stack[0] = 0x1b;
        stack[1] = 'O';
        stack[2] = final;
        return stack[0..3];
    }
    return std.fmt.bufPrint(stack, "\x1b[1;{d}{c}", .{ m, final }) catch stack[0..0];
}

test "encodeKey emits normal and application cursor sequences" {
    var stack: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[A", encodeKey(.up, 0, false, &stack));
    try std.testing.expectEqualStrings("\x1bOA", encodeKey(.up, 0, true, &stack));
    try std.testing.expectEqualStrings("\x1b[C", encodeKey(.right, 0, false, &stack));
}

test "encodeKey encodes modifiers with the xterm parameter" {
    var stack: [16]u8 = undefined;
    // Shift+Right => CSI 1;2 C, even in application mode (modifier forces CSI).
    try std.testing.expectEqualStrings("\x1b[1;2C", encodeKey(.right, mod_shift, true, &stack));
    // Ctrl+Up => CSI 1;5 A
    try std.testing.expectEqualStrings("\x1b[1;5A", encodeKey(.up, mod_ctrl, false, &stack));
    // Alt+Shift+Left => modifier 1 + shift(1) + alt(2) = 4 => CSI 1;4 D
    try std.testing.expectEqualStrings("\x1b[1;4D", encodeKey(.left, mod_shift | mod_alt, false, &stack));
}

test "encodeKey encodes tilde and function keys" {
    var stack: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[3~", encodeKey(.delete, 0, false, &stack));
    try std.testing.expectEqualStrings("\x1b[5;5~", encodeKey(.page_up, mod_ctrl, false, &stack));
    try std.testing.expectEqualStrings("\x1bOP", encodeKey(.f1, 0, false, &stack));
    try std.testing.expectEqualStrings("\x1b[15~", encodeKey(.f5, 0, false, &stack));
    try std.testing.expectEqualStrings("\x1b[24;2~", encodeKey(.f12, mod_shift, false, &stack));
}

test "encodeKey encodes control keys and shift-tab" {
    var stack: [16]u8 = undefined;
    try std.testing.expectEqualStrings("\r", encodeKey(.enter, 0, false, &stack));
    try std.testing.expectEqualStrings("\x7f", encodeKey(.backspace, 0, false, &stack));
    try std.testing.expectEqualStrings("\x1b", encodeKey(.escape, 0, false, &stack));
    try std.testing.expectEqualStrings("\t", encodeKey(.tab, 0, false, &stack));
    try std.testing.expectEqualStrings("\x1b[Z", encodeKey(.tab, mod_shift, false, &stack));
}

test "bridge feeds content, renders a texture, and reports mode/selection" {
    // Exercises the full C-ABI path a Swift host drives: a live session (PTY +
    // renderer + Metal device), feeding VT bytes, rendering to a texture, mode
    // queries, and selection extraction. Feeding directly (without reading the
    // PTY) keeps the visible content deterministic.
    const tab = mostty_tab_create(320, 96, 1, 14) orelse return error.TabCreateFailed;
    defer mostty_tab_destroy(tab);

    try std.testing.expect(mostty_tab_metal_device(tab) != null);
    try std.testing.expect(mostty_tab_at_bottom(tab));
    try std.testing.expect(!mostty_tab_app_cursor_keys(tab));
    try std.testing.expect(!mostty_tab_bracketed_paste(tab));

    const line = "hello world";
    mostty_tab_feed(tab, line.ptr, line.len);

    var cols: u32 = 0;
    var rows: u32 = 0;
    const texture = mostty_tab_render(tab, true, &cols, &rows);
    try std.testing.expect(texture != null);
    try std.testing.expect(cols > 0 and rows > 0);

    var out: [64]u8 = undefined;
    const n = mostty_tab_selection_text(tab, 0, 0, @intCast(line.len - 1), 0, &out, out.len);
    try std.testing.expectEqualStrings(line, out[0..n]);

    // Terminal modes drive input encoding; verify they track VT state.
    mostty_tab_feed(tab, "\x1b[?1h", 5);
    try std.testing.expect(mostty_tab_app_cursor_keys(tab));
    mostty_tab_feed(tab, "\x1b[?2004h", 8);
    try std.testing.expect(mostty_tab_bracketed_paste(tab));
}

test "mostty_tab_title mirrors the Windows path-basename rule" {
    // The tab must read as the current directory name, not the whole path: an
    // OSC-2 path title is reduced to its final component (Windows parity), a
    // non-path title passes through, and a filesystem root reduces to empty so
    // the caller keeps the previous label instead of blanking the tab.
    const tab = mostty_tab_create(320, 96, 1, 14) orelse return error.TabCreateFailed;
    defer mostty_tab_destroy(tab);

    var buf: [256]u8 = undefined;

    const path_title = "\x1b]2;/Users/foo/Development/mostty\x07";
    mostty_tab_feed(tab, path_title.ptr, path_title.len);
    const n_path = mostty_tab_title(tab, &buf, buf.len);
    try std.testing.expectEqualStrings("mostty", buf[0..n_path]);

    const prog_title = "\x1b]2;node\x07";
    mostty_tab_feed(tab, prog_title.ptr, prog_title.len);
    const n_prog = mostty_tab_title(tab, &buf, buf.len);
    try std.testing.expectEqualStrings("node", buf[0..n_prog]);

    const root_title = "\x1b]2;/\x07";
    mostty_tab_feed(tab, root_title.ptr, root_title.len);
    try std.testing.expectEqual(@as(usize, 0), mostty_tab_title(tab, &buf, buf.len));
}
