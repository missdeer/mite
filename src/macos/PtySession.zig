const PtySession = @This();

const builtin = @import("builtin");
const std = @import("std");
const vt = @import("vt");
const TerminalSession = @import("../terminal/Session.zig");

const c = std.c;
const posix = std.posix;

comptime {
    if (builtin.os.tag != .macos) @compileError("PtySession is macOS-only");
}

extern "c" fn forkpty(
    master: *c_int,
    name: ?[*]u8,
    termios: ?*c.termios,
    window_size: ?*posix.winsize,
) c.pid_t;

const TIOCSWINSZ: c_int = @bitCast(@as(u32, 0x80087467));

pub const Exit = union(enum) {
    exited: u8,
    signaled: c.SIG,
    stopped: c.SIG,
    unknown: u32,
};

pub const Hooks = struct {
    context: *anyopaque,
    title_changed: ?*const fn (*anyopaque, *TerminalSession) void = null,
};

pub const Options = struct {
    io: std.Io,
    terminal_allocator: std.mem.Allocator,
    stream_allocator: std.mem.Allocator,
    cols: u16,
    rows: u16,
    shell: ?[:0]const u8 = null,
    command: ?[:0]const u8 = null,
    hooks: ?Hooks = null,
};

terminal: TerminalSession,
master_fd: c.fd_t,
child_pid: ?c.pid_t,
hooks: ?Hooks,
write_failed: bool,

pub fn init(self: *PtySession, options: Options) !void {
    if (options.cols == 0 or options.rows == 0) return error.InvalidSize;

    self.* = .{
        .terminal = undefined,
        .master_fd = -1,
        .child_pid = null,
        .hooks = options.hooks,
        .write_failed = false,
    };
    try self.terminal.init(.{
        .io = options.io,
        .terminal_allocator = options.terminal_allocator,
        .stream_allocator = options.stream_allocator,
        .cols = options.cols,
        .rows = options.rows,
        .hooks = .{
            .context = self,
            .title_changed = onTitleChanged,
            .write_pty = onWritePty,
        },
    });
    errdefer self.terminal.deinit();

    const shell = options.shell orelse defaultShell();
    const environment = try childEnvironment(options.terminal_allocator);
    defer options.terminal_allocator.free(environment);

    var exec_pipe = try createExecPipe();
    errdefer closeFd(exec_pipe[0]);
    errdefer closeFd(exec_pipe[1]);

    var window_size: posix.winsize = .{
        .row = options.rows,
        .col = options.cols,
        .xpixel = 0,
        .ypixel = 0,
    };
    var master_fd: c_int = -1;
    const pid = forkpty(&master_fd, null, null, &window_size);
    if (pid < 0) return error.ForkPtyFailed;

    if (pid == 0) {
        closeFd(exec_pipe[0]);
        execShell(shell, options.command, environment.ptr, exec_pipe[1]);
    }

    closeFd(exec_pipe[1]);
    exec_pipe[1] = -1;
    const exec_failed = readExecFailure(exec_pipe[0]) catch {
        closeFd(master_fd);
        _ = waitPid(pid) catch {};
        return error.ExecHandshakeFailed;
    };
    closeFd(exec_pipe[0]);
    exec_pipe[0] = -1;

    if (exec_failed) {
        closeFd(master_fd);
        _ = waitPid(pid) catch {};
        return error.ShellExecFailed;
    }

    self.master_fd = master_fd;
    self.child_pid = pid;
}

pub fn deinit(self: *PtySession) void {
    self.closeMaster();
    if (self.child_pid) |pid| {
        posix.kill(pid, .HUP) catch {};
        posix.kill(pid, .KILL) catch {};
        _ = waitPid(pid) catch {};
        self.child_pid = null;
    }
    self.terminal.deinit();
    self.* = undefined;
}

pub fn write(self: *PtySession, bytes: []const u8) !void {
    if (self.master_fd < 0) return error.SessionClosed;
    if (self.write_failed) return error.PtyWriteFailed;

    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = c.write(self.master_fd, bytes[offset..].ptr, bytes.len - offset);
        switch (posix.errno(written)) {
            .SUCCESS => offset += @intCast(written),
            .INTR => continue,
            else => return error.PtyWriteFailed,
        }
    }
}

pub fn read(self: *PtySession, buffer: []u8) !usize {
    if (self.master_fd < 0) return error.SessionClosed;
    const count = posix.read(self.master_fd, buffer) catch |err| switch (err) {
        error.InputOutput => return 0,
        else => return err,
    };
    if (count != 0) self.terminal.feed(buffer[0..count]);
    return count;
}

pub fn resize(self: *PtySession, cols: u16, rows: u16) !void {
    if (cols == 0 or rows == 0) return error.InvalidSize;
    if (self.master_fd < 0) return error.SessionClosed;

    const old_cols: u16 = @intCast(self.terminal.term.cols);
    const old_rows: u16 = @intCast(self.terminal.term.rows);
    try resizePty(self.master_fd, cols, rows);
    self.terminal.resize(cols, rows) catch |err| {
        resizePty(self.master_fd, old_cols, old_rows) catch {};
        return err;
    };
}

pub fn wait(self: *PtySession) !Exit {
    const pid = self.child_pid orelse return error.ChildAlreadyReaped;
    const status = try waitPid(pid);
    self.child_pid = null;
    return statusToExit(status);
}

pub fn tryWait(self: *PtySession) !?Exit {
    const pid = self.child_pid orelse return error.ChildAlreadyReaped;
    var status: c_int = undefined;
    while (true) {
        const result = c.waitpid(pid, &status, c.W.NOHANG);
        switch (posix.errno(result)) {
            .SUCCESS => {
                if (result == 0) return null;
                self.child_pid = null;
                return statusToExit(@bitCast(status));
            },
            .INTR => continue,
            else => return error.WaitFailed,
        }
    }
}

fn closeMaster(self: *PtySession) void {
    if (self.master_fd < 0) return;
    closeFd(self.master_fd);
    self.master_fd = -1;
}

fn onTitleChanged(context: *anyopaque, _: *vt.Terminal) void {
    const self: *PtySession = @ptrCast(@alignCast(context));
    const hooks = self.hooks orelse return;
    const callback = hooks.title_changed orelse return;
    callback(hooks.context, &self.terminal);
}

fn onWritePty(context: *anyopaque, bytes: [:0]const u8) void {
    const self: *PtySession = @ptrCast(@alignCast(context));
    self.write(bytes) catch {
        self.write_failed = true;
    };
}

fn defaultShell() [:0]const u8 {
    const shell_ptr = c.getenv("SHELL") orelse return "/bin/zsh";
    const shell = std.mem.span(shell_ptr);
    return if (shell.len == 0) "/bin/zsh" else shell;
}

fn childEnvironment(allocator: std.mem.Allocator) ![:null]?[*:0]const u8 {
    var count: usize = 0;
    var has_term = false;
    while (c.environ[count]) |entry| : (count += 1) {
        if (std.mem.startsWith(u8, std.mem.span(entry), "TERM=")) has_term = true;
    }

    const environment_len = count + @intFromBool(!has_term);
    var environment = try allocator.allocSentinel(?[*:0]const u8, environment_len, null);
    var output_index: usize = 0;
    for (c.environ[0..count]) |entry| {
        const value = entry.?;
        environment[output_index] = if (std.mem.startsWith(u8, std.mem.span(value), "TERM="))
            "TERM=xterm-256color"
        else
            value;
        output_index += 1;
    }
    if (!has_term) environment[output_index] = "TERM=xterm-256color";
    return environment;
}

fn createExecPipe() ![2]c.fd_t {
    var pipe: [2]c.fd_t = undefined;
    if (c.pipe(&pipe) != 0) return error.PipeFailed;
    errdefer closeFd(pipe[0]);
    errdefer closeFd(pipe[1]);

    const flags = c.fcntl(pipe[1], c.F.GETFD);
    if (flags < 0) return error.PipeFailed;
    if (c.fcntl(pipe[1], c.F.SETFD, flags | c.FD_CLOEXEC) != 0) return error.PipeFailed;
    return pipe;
}

fn execShell(
    shell: [:0]const u8,
    command: ?[:0]const u8,
    environment: [*:null]const ?[*:0]const u8,
    error_fd: c.fd_t,
) noreturn {
    const login_arg: [:0]const u8 = "-l";
    const command_arg: [:0]const u8 = "-lc";
    var login_argv = [_:null]?[*:0]const u8{ shell.ptr, login_arg.ptr };
    var command_argv = [_:null]?[*:0]const u8{ shell.ptr, command_arg.ptr, null };
    const argv: [*:null]const ?[*:0]const u8 = if (command) |value| blk: {
        command_argv[2] = value.ptr;
        break :blk &command_argv;
    } else &login_argv;

    _ = c.execve(shell.ptr, argv, environment);
    var exec_errno: c_int = @intFromEnum(posix.errno(-1));
    _ = c.write(error_fd, @ptrCast(&exec_errno), @sizeOf(c_int));
    c._exit(127);
}

fn readExecFailure(fd: c.fd_t) !bool {
    var exec_errno: c_int = 0;
    var received: usize = 0;
    while (received < @sizeOf(c_int)) {
        const bytes: [*]u8 = @ptrCast(&exec_errno);
        const count = c.read(fd, bytes + received, @sizeOf(c_int) - received);
        switch (posix.errno(count)) {
            .SUCCESS => {
                if (count == 0) return received != 0;
                received += @intCast(count);
            },
            .INTR => continue,
            else => return error.ExecHandshakeFailed,
        }
    }
    return true;
}

fn resizePty(fd: c.fd_t, cols: u16, rows: u16) !void {
    var window_size: posix.winsize = .{
        .row = rows,
        .col = cols,
        .xpixel = 0,
        .ypixel = 0,
    };
    if (c.ioctl(fd, TIOCSWINSZ, &window_size) != 0) return error.PtyResizeFailed;
}

fn waitPid(pid: c.pid_t) !u32 {
    var status: c_int = undefined;
    while (true) {
        const result = c.waitpid(pid, &status, 0);
        switch (posix.errno(result)) {
            .SUCCESS => return @bitCast(status),
            .INTR => continue,
            else => return error.WaitFailed,
        }
    }
}

fn statusToExit(status: u32) Exit {
    if (c.W.IFEXITED(status)) return .{ .exited = c.W.EXITSTATUS(status) };
    if (c.W.IFSIGNALED(status)) return .{ .signaled = c.W.TERMSIG(status) };
    if (c.W.IFSTOPPED(status)) return .{ .stopped = c.W.STOPSIG(status) };
    return .{ .unknown = status };
}

fn closeFd(fd: c.fd_t) void {
    if (fd >= 0) _ = c.close(fd);
}

fn drainToEof(session: *PtySession) !void {
    var buffer: [4096]u8 = undefined;
    while (try session.read(&buffer) != 0) {}
}

test "macOS PTY starts a shell and exchanges data through the VT session" {
    var session: PtySession = undefined;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .shell = "/bin/sh",
        .command = "printf '\\033]0;pty-test\\007'; read line; printf 'seen:%s\\n' \"$line\"; exit 7",
    });
    defer session.deinit();

    try session.write("round-trip\n");
    try drainToEof(&session);
    const exit = try session.wait();
    try std.testing.expectEqual(@as(u8, 7), exit.exited);
    try std.testing.expectEqualStrings("pty-test", session.terminal.term.getTitle().?);

    const contents = try session.terminal.term.plainString(std.testing.allocator);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "seen:round-trip") != null);
}

test "macOS PTY resize reaches both the child and VT grid" {
    var session: PtySession = undefined;
    try session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .shell = "/bin/sh",
        .command = "read line; stty size",
    });
    defer session.deinit();

    try session.resize(100, 40);
    try session.write("report\n");
    try drainToEof(&session);
    const exit = try session.wait();
    try std.testing.expectEqual(@as(u8, 0), exit.exited);
    try std.testing.expectEqual(@as(usize, 100), session.terminal.term.cols);
    try std.testing.expectEqual(@as(usize, 40), session.terminal.term.rows);

    const contents = try session.terminal.term.plainString(std.testing.allocator);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "40 100") != null);
}

test "macOS PTY reports an exec failure without leaving a child session" {
    var session: PtySession = undefined;
    try std.testing.expectError(error.ShellExecFailed, session.init(.{
        .io = std.testing.io,
        .terminal_allocator = std.testing.allocator,
        .stream_allocator = std.testing.allocator,
        .cols = 80,
        .rows = 24,
        .shell = "/definitely/not/a/shell",
    }));
}
