const Cmdline = @This();

font_path: ?[]const u8 = null,
font_size: f32 = 16.0,
renderer: RendererSelection = .from_config,

pub const RendererSelection = union(enum) {
    from_config,
    backend: Config.RendererBackend,
    invalid: []const u8,
};

pub fn usage() !void {
    try std.fs.File.stderr().writeAll(
        \\Usage: Mostty [options]
        \\
        \\Font Options:
        \\  --ttf <path>              Use TrueType font at <path>
        \\  --font-size <float>       Font size (scaled by DPI, default: 16.0)
        \\
        \\Renderer Options:
        \\  --renderer <backend>      Renderer backend (d3d11, d3d12, opengl,
        \\                            pure-opengl, vulkan, or native-vulkan)
        \\
    );
}

pub fn parse(args: *std.process.ArgIterator) !Cmdline {
    var result: Cmdline = .{};
    _ = args.next(); // skip program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ttf")) {
            result.font_path = args.next() orelse errExit("--ttf requires a path argument", .{});
        } else if (std.mem.eql(u8, arg, "--font-size")) {
            const size_str = args.next() orelse errExit("--font-size requires an argument", .{});
            result.font_size = std.fmt.parseFloat(f32, size_str) catch errExit(
                "invalid --font-size '{s}'",
                .{size_str},
            );
            if (result.font_size <= 0) errExit(
                "invalid --font-size  '{d}' (must be positive)",
                .{result.font_size},
            );
            std.log.info("--font-size {d}", .{result.font_size});
        } else if (std.mem.eql(u8, arg, "--renderer")) {
            const value = args.next() orelse errExit("--renderer requires an argument", .{});
            result.renderer = parseRenderer(value);
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try Cmdline.usage();
            std.process.exit(0);
        } else errExit("unknown cmdline option '{s}'", .{arg});
    }
    return result;
}

pub fn rendererOr(self: Cmdline, configured: Config.RendererBackend) Config.RendererBackend {
    return switch (self.renderer) {
        .from_config => configured,
        .backend => |backend| backend,
        .invalid => unreachable,
    };
}

fn parseRenderer(value: []const u8) RendererSelection {
    const backend = std.meta.stringToEnum(Config.RendererBackend, value) orelse
        return .{ .invalid = value };
    return .{ .backend = backend };
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

test "renderer accepts exactly the configured backend names" {
    inline for (std.meta.tags(Config.RendererBackend)) |backend| {
        try std.testing.expectEqual(backend, parseRenderer(@tagName(backend)).backend);
    }
    try std.testing.expectEqualStrings("D3D11", parseRenderer("D3D11").invalid);
    try std.testing.expectEqualStrings("native_vulkan", parseRenderer("native_vulkan").invalid);
}

test "renderer command-line value overrides config and omission preserves it" {
    const configured: Config.RendererBackend = .opengl;
    try std.testing.expectEqual(configured, (Cmdline{}).rendererOr(configured));
    try std.testing.expectEqual(Config.RendererBackend.vulkan, (Cmdline{ .renderer = .{ .backend = .vulkan } }).rendererOr(configured));
}

const Config = @import("Config.zig");
const builtin = @import("builtin");
const std = @import("std");
