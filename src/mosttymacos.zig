pub const TerminalSession = @import("terminal/Session.zig");

comptime {
    _ = @sizeOf(TerminalSession);
}
