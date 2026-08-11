const std = @import("std");
const win32 = @import("win32").everything;

threadlocal var thread_is_panicking = false;

pub fn threadIsPanicking() bool {
    return thread_is_panicking;
}

/// Latches the panic state; true only for the entry that owns crash reporting.
pub fn enterPanic() bool {
    if (thread_is_panicking) return false;
    thread_is_panicking = true;
    return true;
}

pub fn panicHandler(msg: []const u8, ret_addr: ?usize) noreturn {
    if (enterPanic()) {
        crashMessageBox(msg, ret_addr orelse @returnAddress());
    }
    std.debug.defaultPanic(msg, ret_addr);
}

fn crashMessageBox(msg: []const u8, ret_addr: usize) void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    // don't free, we're about to crash
    const arena = arena_instance.allocator();
    var allocating: std.Io.Writer.Allocating = .init(arena);
    const write_result = writeCrash(&allocating.writer, msg, ret_addr);
    const final_msg: [*:0]const u8 = blk: {
        write_result catch {
            const marker = "[TRUNCATED]";
            const buf = allocating.writer.buffer;
            if (buf.len <= marker.len) break :blk "failed to allocate memory for error";
            const max_start = buf.len - marker.len - 1;
            const start = @min(allocating.writer.end, max_start);
            @memcpy(buf[start..][0..marker.len], marker);
            buf[start + marker.len] = 0;
        };
        break :blk @ptrCast(allocating.writer.buffer.ptr);
    };
    _ = win32.MessageBoxA(null, final_msg, "Mostty Crashed", .{ .ICONHAND = 1 });
}

fn writeCrash(writer: *std.Io.Writer, msg: []const u8, ret_addr: usize) error{WriteFailed}!void {
    try writer.print("{s}\n\n", .{msg});
    try std.debug.writeCurrentStackTrace(
        .{ .first_address = ret_addr },
        .{ .writer = writer, .mode = .no_color },
    );
    try writer.writeByte(0);
}

test "only the first panic entry on a thread reports the crash" {
    const Probe = struct {
        first: bool = false,
        nested: bool = false,

        fn run(self: *@This()) void {
            self.first = enterPanic();
            self.nested = enterPanic();
        }
    };

    var probe: Probe = .{};
    const thread = try std.Thread.spawn(.{}, Probe.run, .{&probe});
    thread.join();

    try std.testing.expect(probe.first);
    // A re-entrant panic must not report again, so the crash the user sees stays
    // the first one.
    try std.testing.expect(!probe.nested);
    try std.testing.expect(!threadIsPanicking());
}
