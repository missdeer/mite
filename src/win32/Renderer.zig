const Renderer = @This();

const std = @import("std");
const vt = @import("vt");
const win32 = @import("win32").everything;

const Config = @import("../Config.zig");
const d3d11 = @import("d3d11.zig");
const gl46 = @import("gl46.zig");
const FontService = @import("FontService.zig");
const types = @import("types.zig");

pub const d3d12 = @import("d3d12.zig");

pub const RendererCommon = @import("RendererCommon.zig");
const shared = @import("shared.zig");
const gpu = @import("d3d11/gpu.zig");

pub const BgImageDecoded = d3d11.BgImageDecoded;
pub const RasterResult = FontService.RasterResult;
pub const FontConfig = FontService.FontConfig;
pub const scrollbarWidth = d3d11.scrollbarWidth;
pub const default_primary_font_family = FontService.default_primary_font_family;
pub const default_font_size_pt = FontService.default_font_size_pt;

/// Backends are all-or-nothing: every variant here fulfils the whole contract
/// below, because the facade dispatches every method to whichever one is
/// selected and a variant that could only draw part of the picture would be a
/// selectable broken terminal.
pub const RendererBackend = union(enum) {
    d3d11: d3d11,
    /// Verified for static and low-frequency correctness only. Selectable on
    /// request for comparison work, never the default, and not to be
    /// described as fully capable until sustained-load behaviour is settled.
    d3d12: d3d12.Renderer,
    /// OpenGL research path: complete baseline rendering through WGL and
    /// shared SPIR-V, with optional DirectComposition interoperability.
    opengl: gl46,
};

pub const StartupFallback = struct {
    configured: Config.RendererBackend,
    replacement: Config.RendererBackend = .d3d11,

    pub fn selectedBackend(self: StartupFallback, accepted: bool) ?Config.RendererBackend {
        return if (accepted) self.replacement else null;
    }
};

pub fn recommendStartupFallback(
    backend: Config.RendererBackend,
    startup_failed: bool,
) ?StartupFallback {
    if (!startup_failed or backend == .d3d11) return null;
    return .{ .configured = backend };
}

pub const StartupFailure = union(enum) {
    d3d12: d3d12.Renderer.StartupError,
    opengl: gl46.StartupError,

    pub fn description(self: StartupFailure) []const u8 {
        return switch (self) {
            .d3d12 => |err| d3d12.Renderer.startupErrorDescription(err),
            .opengl => |err| gl46.startupErrorDescription(err),
        };
    }

    pub fn codeName(self: StartupFailure) []const u8 {
        return switch (self) {
            .d3d12 => |err| @errorName(err),
            .opengl => |err| @errorName(err),
        };
    }
};

common: RendererCommon,
font_service: FontService,
configured_backend: Config.RendererBackend,
backend: ?RendererBackend,

// Initialize in place: the backend borrows `common`, and the async glyph
// worker later borrows backend state. The process-global renderer provides
// the stable address required by both relationships.
pub fn init(
    self: *Renderer,
    dpi: u32,
    font_config: FontConfig,
    font_ligatures: bool,
    configured_gpu: ?[]const u8,
    backend: Config.RendererBackend,
) void {
    // The font service and the backend resolve the adapter from the same
    // configured name, which is what keeps them on one GPU. Splitting them
    // across adapters would leave rasterization and compositing on different
    // hardware and the visual-equivalence baseline would stop being single.
    self.font_service = FontService.init(
        &self.common,
        dpi,
        font_config,
        font_ligatures,
        configured_gpu,
    );
    self.configured_backend = backend;
    self.backend = switch (backend) {
        .d3d11 => .{ .d3d11 = d3d11.init(&self.common, &self.font_service, configured_gpu) },
        .d3d12 => null,
        .opengl => .{
            .opengl = gl46.init(&self.common, &self.font_service, configured_gpu, .interop),
        },
        .@"pure-opengl" => .{
            .opengl = gl46.init(&self.common, &self.font_service, configured_gpu, .pure_wgl),
        },
    };
}

test "research backend startup failure offers an explicit D3D11 fallback" {
    const fallback = recommendStartupFallback(.opengl, true).?;
    try std.testing.expectEqual(Config.RendererBackend.opengl, fallback.configured);
    try std.testing.expectEqual(
        Config.RendererBackend.d3d11,
        fallback.selectedBackend(true).?,
    );
    try std.testing.expectEqual(@as(?Config.RendererBackend, null), fallback.selectedBackend(false));
    try std.testing.expectEqual(Config.RendererBackend.d3d11, recommendStartupFallback(.d3d12, true).?.replacement);
}

test "successful startup and D3D11 failure do not offer a fallback" {
    try std.testing.expectEqual(@as(?StartupFallback, null), recommendStartupFallback(.opengl, false));
    try std.testing.expectEqual(@as(?StartupFallback, null), recommendStartupFallback(.d3d11, true));
}

test "pure-opengl startup failure retains its configured identity" {
    const fallback = recommendStartupFallback(.@"pure-opengl", true).?;
    try std.testing.expectEqual(Config.RendererBackend.@"pure-opengl", fallback.configured);
    try std.testing.expectEqual(Config.RendererBackend.d3d11, fallback.replacement);
}

test "startup failure retains its backend-specific reason" {
    const failure: StartupFailure = .{ .opengl = error.VersionTooOld };
    try std.testing.expectEqualStrings("VersionTooOld", failure.codeName());
    try std.testing.expectEqualStrings(
        "the driver exposed an OpenGL version older than 4.6",
        failure.description(),
    );
    const d3d12_failure: StartupFailure = .{ .d3d12 = error.DeviceUnavailable };
    try std.testing.expectEqualStrings("DeviceUnavailable", d3d12_failure.codeName());
    try std.testing.expectEqualStrings(
        "no D3D12 device supports feature level 11_0",
        d3d12_failure.description(),
    );
}

pub fn initializeWindow(
    self: *Renderer,
    hwnd: win32.HWND,
    configured_gpu: ?[]const u8,
) ?StartupFailure {
    if (self.backend == null) {
        std.debug.assert(self.configured_backend == .d3d12);
        var backend = d3d12.Renderer.init(
            &self.common,
            &self.font_service,
            configured_gpu,
        ) catch |err| return .{ .d3d12 = err };
        backend.initializeWindow(hwnd) catch |err| {
            backend.deinit();
            return .{ .d3d12 = err };
        };
        self.backend = .{ .d3d12 = backend };
        return null;
    }
    return switch (self.backend.?) {
        .opengl => |*backend| blk: {
            backend.initializeWindow(hwnd) catch |err| break :blk .{ .opengl = err };
            break :blk null;
        },
        else => null,
    };
}

pub fn fallbackToD3d11(self: *Renderer, configured_gpu: ?[]const u8) void {
    if (self.backend) |*active| switch (active.*) {
        .d3d11 => return,
        inline else => |*backend| backend.deinit(),
    };
    self.configured_backend = .d3d11;
    self.backend = .{ .d3d11 = d3d11.init(&self.common, &self.font_service, configured_gpu) };
}

fn activeBackend(self: *Renderer) *RendererBackend {
    return if (self.backend) |*backend| backend else @panic("renderer backend used before its startup capability gate");
}

fn deinitBackend(self: *Renderer) void {
    if (self.backend) |*active| switch (active.*) {
        inline else => |*backend| backend.deinit(),
    };
}

pub fn cellSizeForDpi(self: *Renderer, dpi: u32) win32.SIZE {
    return self.font_service.cellSizeForDpi(dpi);
}

pub fn tabBarHeightForDpi(self: *Renderer, dpi: u32) i32 {
    return self.font_service.tabBarHeightForDpi(dpi);
}

pub fn updateDpi(self: *Renderer, dpi: u32) void {
    if (self.font_service.updateDpi(dpi)) {
        switch (self.activeBackend().*) {
            inline else => |*backend| backend.onFontStateChanged(),
        }
    }
}

pub fn updateFont(self: *Renderer, font_config: FontConfig) void {
    self.font_service.updateFont(font_config);
    switch (self.activeBackend().*) {
        inline else => |*backend| backend.onFontStateChanged(),
    }
}

pub fn deinit(self: *Renderer) void {
    self.deinitBackend();
    self.font_service.deinit();
    self.* = undefined;
}

pub fn render(
    self: *Renderer,
    hwnd: win32.HWND,
    tab_id: types.TabId,
    term: *vt.Terminal,
    tabbar: types.TabBarDraw,
    resizing: bool,
    mouse_in_scrollbar: bool,
    selection_fade: f32,
    cursor_text: ?u24,
    selection_bg: ?u24,
    selection_fg: ?u24,
    background_opacity: f32,
    remote_session: bool,
    url_highlight: ?types.UrlHighlight,
) void {
    switch (self.activeBackend().*) {
        inline else => |*backend| backend.render(
            hwnd,
            tab_id,
            term,
            tabbar,
            resizing,
            mouse_in_scrollbar,
            selection_fade,
            cursor_text,
            selection_bg,
            selection_fg,
            background_opacity,
            remote_session,
            url_highlight,
        ),
    }
}

pub fn setWorkerHwnd(self: *Renderer, gpa: std.mem.Allocator, hwnd: win32.HWND) void {
    self.font_service.setWorkerHwnd(gpa, hwnd);
}

pub fn applyGlyphResult(self: *Renderer, result: *RasterResult) bool {
    return switch (self.activeBackend().*) {
        inline else => |*backend| backend.applyGlyphResult(result),
    };
}

pub fn reloadBackgroundImage(
    self: *Renderer,
    gpa: std.mem.Allocator,
    cfg: *const Config,
    hwnd: win32.HWND,
) void {
    switch (self.activeBackend().*) {
        inline else => |*backend| backend.reloadBackgroundImage(gpa, cfg, hwnd),
    }
}

pub fn applyDecodedBackgroundImage(self: *Renderer, result: *const BgImageDecoded) void {
    switch (self.activeBackend().*) {
        inline else => |*backend| backend.applyDecodedBackgroundImage(result),
    }
}

pub fn releaseKittyImagesForTab(self: *Renderer, tab_id: types.TabId) void {
    if (self.backend == null) return;
    switch (self.activeBackend().*) {
        inline else => |*backend| backend.releaseKittyImagesForTab(tab_id),
    }
}

test "every selectable backend answers the whole facade contract" {
    // The facade dispatches each of these to whichever variant is selected,
    // so a variant missing any one of them would be a selectable terminal
    // that cannot draw part of its picture. Fulfilling the contract is what
    // earns selectability, so assert it of every variant rather than trusting
    // that the union was extended carefully.
    const contract = .{
        "init",                        "deinit",
        "render",                      "onFontStateChanged",
        "applyGlyphResult",            "reloadBackgroundImage",
        "applyDecodedBackgroundImage", "releaseKittyImagesForTab",
    };
    inline for (@typeInfo(RendererBackend).@"union".fields) |field| {
        inline for (contract) |name| {
            try std.testing.expect(@hasDecl(field.type, name));
        }
    }
}

test "d3d11 stays the default so an untouched install is unaffected" {
    // D3D12 is verified only for static and low-frequency correctness; it may
    // be asked for, but it must never become what a user gets by default.
    try std.testing.expectEqual(Config.RendererBackend.d3d11, (Config{}).renderer);
    try std.testing.expectEqualStrings(
        "d3d11",
        @typeInfo(RendererBackend).@"union".fields[0].name,
    );
}

test "all backends consume one rasterizer, differing only in handoff form" {
    // Text coverage compositing is judged against d3d11, and that comparison
    // only means anything while both backends render from the same glyph
    // source. Differing handoff form is expected; a second rasterizer is not.
    try std.testing.expectEqual(shared.GlyphHandoff.shared_surface, d3d11.glyph_handoff);
    try std.testing.expectEqual(shared.GlyphHandoff.cpu_pixels, d3d12.Renderer.glyph_handoff);
    try std.testing.expectEqual(shared.GlyphHandoff.cpu_pixels, gl46.glyph_handoff);
    inline for (@typeInfo(RendererBackend).@"union".fields) |field| {
        // Neither backend may own font machinery; it belongs to the service.
        inline for (.{ "dwrite_factory", "d2d_factory", "text_formats" }) |owned_by_service| {
            try std.testing.expect(!@hasField(field.type, owned_by_service));
        }
    }
}

test "a wide glyph's two halves are copied under one surface acquisition" {
    // The font-service handoff alternates keys, so acquiring twice without an
    // intervening write blocks the UI thread forever. Taking both halves in
    // one call is what makes that impossible; a signature accepting a single
    // region would invite the caller to loop and deadlock instead.
    const params = @typeInfo(@TypeOf(d3d11.atlasCopyStaging)).@"fn".params;
    try std.testing.expectEqual(@as(usize, 4), params.len);
    try std.testing.expectEqual(?gpu.AtlasCopy, params[2].type.?);
    try std.testing.expectEqual(?gpu.AtlasCopy, params[3].type.?);
}

test "backend does not duplicate renderer common state" {
    inline for (.{ "cell_size", "tab_bar_height", "font_ligatures", "remote_or_software_adapter" }) |field_name| {
        try std.testing.expect(@hasField(RendererCommon, field_name));
        try std.testing.expect(!@hasField(d3d11, field_name));
    }
    try std.testing.expect(@hasField(d3d11, "common"));
}

test "font service owns font and raster lifecycle outside the backend" {
    try std.testing.expect(@hasField(Renderer, "font_service"));
    try std.testing.expect(@hasField(FontService, "device"));
    try std.testing.expect(@hasField(FontService, "glyph_worker"));
    try std.testing.expect(@hasField(d3d11, "font_service"));
    inline for (.{ "dwrite_factory", "d2d_factory", "text_formats", "glyph_worker", "staging_texture" }) |field_name| {
        try std.testing.expect(@hasField(FontService, field_name));
        try std.testing.expect(!@hasField(d3d11, field_name));
    }
}
