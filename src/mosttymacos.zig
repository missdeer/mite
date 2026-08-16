pub const TerminalSession = @import("terminal/Session.zig");
pub const PtySession = @import("macos/PtySession.zig");

comptime {
    _ = @sizeOf(TerminalSession);
    _ = @sizeOf(PtySession);
}
