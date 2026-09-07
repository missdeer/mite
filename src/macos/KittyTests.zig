const std = @import("std");
const vt = @import("vt");
const Session = @import("../terminal/Session.zig");
const Renderer = @import("CoreTextRenderer.zig");
const alloc = std.testing.allocator;

const Fixture = struct {
    session: Session,
    renderer: Renderer,
    response: [256]u8 = undefined,
    response_len: usize = 0,

    fn init(self: *Fixture) !void {
        @import("PngDecoder.zig").install();
        self.response_len = 0;
        self.renderer = try Renderer.init(.{ .allocator = alloc, .pixel_width = 240, .pixel_height = 160, .paint = .{ .background_alpha = 255 } });
        errdefer self.renderer.deinit();
        const grid = self.renderer.gridSize();
        try self.session.init(.{ .io = std.testing.io, .terminal_allocator = alloc, .stream_allocator = alloc, .cols = @intCast(grid.cols), .rows = @intCast(grid.rows), .hooks = .{ .context = self, .write_pty = write } });
        self.session.syncPixelSize(self.renderer.metrics.cell_width, self.renderer.metrics.cell_height);
        self.session.feed("\x1b]11;#000000\x07");
    }

    fn deinit(self: *Fixture) void {
        self.renderer.deinit();
        self.session.deinit();
    }

    fn write(context: *anyopaque, data: [:0]const u8) void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.response_len = @min(data.len, self.response.len);
        @memcpy(self.response[0..self.response_len], data[0..self.response_len]);
    }

    fn transmit(self: *Fixture, options: []const u8, pixels: []const u8) !void {
        const encoded = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(pixels.len));
        defer alloc.free(encoded);
        _ = std.base64.standard.Encoder.encode(encoded, pixels);
        const command = try std.fmt.allocPrint(alloc, "\x1b_G{s};{s}\x1b\\", .{ options, encoded });
        defer alloc.free(command);
        self.session.feed(command);
    }

    fn render(self: *Fixture) !void {
        _ = try self.renderer.render(&self.session, null);
    }

    fn pixel(self: *const Fixture, x: u32, y: u32) [4]u8 {
        const bytes = self.renderer.pixels[(@as(usize, y) * self.renderer.pixel_width + x) * 4 ..][0..4];
        return .{ bytes[2], bytes[1], bytes[0], bytes[3] };
    }

    fn expectPixel(self: *const Fixture, x: u32, y: u32, expected: [4]u8) !void {
        try std.testing.expectEqualSlices(u8, &expected, &self.pixel(x, y));
    }
};

test "Kitty direct RGBA ACK, orientation, alpha, crop, replacement and deletion" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    f.session.feed("\x1b]11;#0000ff\x07");
    try f.transmit("a=T,f=32,s=2,v=2,i=1,c=4,r=4,C=1", &.{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 0, 0, 0, 0 });
    try std.testing.expectEqualStrings("\x1b_Gi=1;OK\x1b\\", f.response[0..f.response_len]);
    try f.render();
    const cw = f.renderer.metrics.cell_width;
    const ch = f.renderer.metrics.cell_height;
    try f.expectPixel(cw, ch, .{ 255, 0, 0, 255 });
    try f.expectPixel(3 * cw, ch, .{ 0, 128, 127, 255 });
    try f.expectPixel(cw, 3 * ch, .{ 0, 0, 255, 255 });
    try f.expectPixel(3 * cw, 3 * ch, .{ 0, 0, 255, 255 });
    const generation = f.renderer.kitty_images.images.get(1).?.generation;
    f.session.feed("\x1b_Ga=d,d=a\x1b\\\x1b_Ga=p,i=1,x=1,y=0,w=1,h=1,c=2,r=2,C=1\x1b\\");
    try f.render();
    try f.expectPixel(cw, ch, .{ 0, 128, 127, 255 });
    try f.transmit("a=T,f=24,s=1,v=1,i=1,c=2,r=2,C=1", &.{ 255, 255, 0 });
    try f.render();
    try std.testing.expect(f.renderer.kitty_images.images.get(1).?.generation != generation);
    try f.expectPixel(cw, ch, .{ 255, 255, 0, 255 });
    f.session.feed("\x1b_Ga=d,d=I,i=1\x1b\\");
    try f.render();
    try std.testing.expectEqual(@as(u32, 0), f.renderer.kitty_images.images.count());
    try f.expectPixel(cw, ch, .{ 0, 0, 255, 255 });
}

test "Kitty z layers preserve explicit backgrounds and text" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const cw = f.renderer.metrics.cell_width;
    const ch = f.renderer.metrics.cell_height;
    // Full-block sprites make foreground coverage deterministic at cell centers.
    f.session.feed("\x1b[38;2;255;255;255m\u{2588}\x1b[48;2;0;0;255m \x1b[0m\x1b[H");
    for ([_]struct { z: i32, first: [4]u8, second: [4]u8 }{
        .{ .z = -1073741825, .first = .{ 255, 255, 255, 255 }, .second = .{ 0, 0, 255, 255 } },
        .{ .z = -1, .first = .{ 255, 255, 255, 255 }, .second = .{ 255, 0, 0, 255 } },
        .{ .z = 0, .first = .{ 255, 0, 0, 255 }, .second = .{ 255, 0, 0, 255 } },
    }) |case| {
        f.session.feed("\x1b_Ga=d,d=A\x1b\\");
        const options = try std.fmt.allocPrint(alloc, "a=T,f=24,s=1,v=1,i=1,c=3,r=1,C=1,z={d}", .{case.z});
        defer alloc.free(options);
        try f.transmit(options, &.{ 255, 0, 0 });
        try f.render();
        try f.expectPixel(cw / 2, ch / 2, case.first);
        try f.expectPixel(cw + cw / 2, ch / 2, case.second);
        try f.expectPixel(2 * cw + cw / 2, ch / 2, .{ 255, 0, 0, 255 });
    }
    // Higher z wins regardless of transmission/image-ID ordering.
    try f.transmit("a=T,f=24,s=1,v=1,i=2,c=3,r=1,C=1,z=2", &.{ 0, 255, 0 });
    try f.transmit("a=T,f=24,s=1,v=1,i=3,c=3,r=1,C=1,z=1", &.{ 0, 0, 255 });
    try f.render();
    try f.expectPixel(cw / 2, ch / 2, .{ 0, 255, 0, 255 });
}

test "Kitty clipping, scrolling, alternate screens and renderer ownership" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    const cw = f.renderer.metrics.cell_width;
    const ch = f.renderer.metrics.cell_height;
    try f.transmit("a=T,f=24,s=1,v=2,i=1,c=2,r=4,C=1", &.{ 255, 0, 0, 0, 255, 0 });
    const rows = f.session.term.rows;
    for (0..rows + 4) |_| f.session.feed("\r\n");
    f.session.term.scrollViewport(.top);
    try f.render();
    try f.expectPixel(cw, ch, .{ 255, 0, 0, 255 });
    f.session.term.scrollViewport(.{ .row = 2 });
    try f.render();
    try f.expectPixel(cw, ch, .{ 0, 255, 0, 255 });
    f.session.feed("\x1b[?1049h\x1b[H");
    try f.render();
    try std.testing.expectEqual(@as(u32, 0), f.renderer.kitty_images.images.count());
    try f.transmit("a=T,f=24,s=1,v=1,i=1,c=2,r=2,C=1", &.{ 0, 0, 255 });
    try f.render();
    try f.expectPixel(cw, ch, .{ 0, 0, 255, 255 });
    f.session.feed("\x1b[?1049l");
    try f.render();
    try f.expectPixel(cw, ch, .{ 0, 255, 0, 255 });
    f.session.term.scrollViewport(.bottom);
    const move = try std.fmt.allocPrint(alloc, "\x1b[{d};{d}H", .{ rows, f.session.term.cols });
    defer alloc.free(move);
    f.session.feed(move);
    try f.transmit("a=T,f=24,s=1,v=1,i=2,c=100,r=100,C=1", &.{ 255, 255, 255 });
    try f.render();
    try f.expectPixel((f.session.term.cols - 1) * cw, (rows - 1) * ch, .{ 255, 255, 255, 255 });
    try f.expectPixel(0, f.renderer.pixel_height - 1, .{ 0, 0, 0, 255 });
    var other: Fixture = undefined;
    try other.init();
    defer other.deinit();
    try other.render();
    try std.testing.expectEqual(@as(u32, 0), other.renderer.kitty_images.images.count());
    try other.expectPixel(cw, ch, .{ 0, 0, 0, 255 });
}

test "Kitty Unicode placeholders use VT placement geometry without glyph boxes" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.transmit("a=T,f=24,s=1,v=1,i=42,c=1,r=1,U=1", &.{ 255, 0, 0 });
    f.session.feed("\x1b[38;5;42m\u{10EEEE}\u{0305}\u{0305}\x1b[0m");
    try f.render();
    try std.testing.expectEqual(@as(usize, 1), f.renderer.kitty_images.placements.items.len);
    const cw = f.renderer.metrics.cell_width;
    const ch = f.renderer.metrics.cell_height;
    try f.expectPixel(cw / 2, ch / 2, .{ 255, 0, 0, 255 });
    f.session.feed("\x1b_Ga=d,d=I,i=42\x1b\\");
    try f.render();
    for (0..ch) |y| for (0..cw) |x| {
        try f.expectPixel(@intCast(x), @intCast(y), .{ 0, 0, 0, 255 });
    };
}

test "Kitty PNG uses ImageIO with straight alpha and rejects invalid payloads" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    // PNG fixture encoded independently with Go image/png: red, half-alpha green,
    // blue and transparent black, in top-to-bottom order.
    const encoded = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAHElEQVR4nATAAREAAAgDIc7kNv9xkTwKFgAA//87AAV+M2k18gAAAABJRU5ErkJggg==";
    var png: [try std.base64.standard.Decoder.calcSizeForSlice(encoded)]u8 = undefined;
    try std.base64.standard.Decoder.decode(&png, encoded);
    const decoded = try vt.sys.decode_png.?(alloc, &png);
    defer alloc.free(decoded.data);
    try std.testing.expectEqual(@as(u32, 2), decoded.width);
    try std.testing.expectEqual(@as(u32, 2), decoded.height);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 0, 0, 0, 0 }, decoded.data);
    try f.transmit("a=T,f=100,i=6,c=4,r=4,C=1", &png);
    try std.testing.expectEqualStrings("\x1b_Gi=6;OK\x1b\\", f.response[0..f.response_len]);
    try f.render();
    const cw = f.renderer.metrics.cell_width;
    const ch = f.renderer.metrics.cell_height;
    try f.expectPixel(cw, ch, .{ 255, 0, 0, 255 });
    try f.expectPixel(3 * cw, ch, .{ 0, 128, 0, 255 });
    try f.expectPixel(cw, 3 * ch, .{ 0, 0, 255, 255 });
    try f.expectPixel(3 * cw, 3 * ch, .{ 0, 0, 0, 255 });
    try f.transmit("a=T,f=100,i=7", "not a PNG");
    try std.testing.expect(std.mem.indexOf(u8, f.response[0..f.response_len], "EINVAL") != null);
    try std.testing.expect(f.session.term.screens.active.kitty_images.imageById(7) == null);
    try std.testing.expectError(error.InvalidData, vt.sys.decode_png.?(alloc, "not a PNG"));
}

test "Kitty chunk completion and query replies do not publish partial images" {
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.transmit("a=q,f=24,s=1,v=1,i=99", &.{ 255, 0, 0 });
    try std.testing.expectEqualStrings("\x1b_Gi=99;OK\x1b\\", f.response[0..f.response_len]);
    try std.testing.expect(f.session.term.screens.active.kitty_images.imageById(99) == null);
    f.response_len = 0;
    try f.transmit("a=T,f=32,s=1,v=2,i=8,c=2,r=4,C=1,m=1", &.{ 255, 0, 0, 255 });
    try std.testing.expectEqual(@as(usize, 0), f.response_len);
    try f.render();
    try std.testing.expectEqual(@as(u32, 0), f.renderer.kitty_images.images.count());
    try f.transmit("m=0", &.{ 0, 255, 0, 255 });
    try std.testing.expectEqualStrings("\x1b_Gi=8;OK\x1b\\", f.response[0..f.response_len]);
    try f.render();
    try f.expectPixel(f.renderer.metrics.cell_width, f.renderer.metrics.cell_height, .{ 255, 0, 0, 255 });
    try f.expectPixel(f.renderer.metrics.cell_width, 3 * f.renderer.metrics.cell_height, .{ 0, 255, 0, 255 });
}
