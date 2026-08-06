const std = @import("std");
const win32 = @import("win32").everything;
const state = @import("state.zig");

var enabled: bool = false;
var file: ?std.Io.File = null;
var mutex: std.Io.Mutex = .init;

pub fn isEnabled() bool {
    return enabled;
}

pub fn init() void {
    const environ: std.process.Environ = .{ .block = .global };
    const value = environ.getAlloc(std.heap.page_allocator, "MOSTTY_DIAG") catch return;
    defer std.heap.page_allocator.free(value);
    enabled = true;

    const io = std.Io.Threaded.global_single_threaded.io();
    const path = "tmp\\mostty-diag.log";
    if (std.fs.path.dirname(path)) |dir| {
        std.Io.Dir.cwd().createDirPath(io, dir) catch return;
    }
    file = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch return;
    log(.info, .diag, "diag enabled: {s}", .{path});
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!enabled) return;
    const f = file orelse return;

    const io = std.Io.Threaded.global_single_threaded.io();
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    const level_txt = comptime level.asText();
    const prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";
    var buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "[{}] " ++ level_txt ++ " " ++ prefix ++ format ++ "\n",
        .{win32.GetTickCount64()} ++ args,
    ) catch return;
    f.writeStreamingAll(io, line) catch return;
}

pub fn qpcNow() u64 {
    return state.qpcNow();
}

pub fn qpcUsSince(prev: u64) u64 {
    return state.qpcUsSince(prev);
}
