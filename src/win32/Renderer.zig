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
    reason: Reason,

    pub const Reason = enum {
        remote_session,
    };

    pub fn selectedBackend(self: StartupFallback, accepted: bool) ?Config.RendererBackend {
        return if (accepted) self.replacement else null;
    }
};

pub fn recommendStartupFallback(
    backend: Config.RendererBackend,
    remote_session: bool,
) ?StartupFallback {
    if (backend == .opengl and remote_session) {
        return .{ .configured = backend, .reason = .remote_session };
    }
    return null;
}

common: RendererCommon,
font_service: FontService,
backend: RendererBackend,

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
    self.backend = switch (backend) {
        .d3d11 => .{ .d3d11 = d3d11.init(&self.common, &self.font_service, configured_gpu) },
        .d3d12 => .{
            .d3d12 = d3d12.Renderer.init(&self.common, &self.font_service, configured_gpu),
        },
        .opengl => .{
            .opengl = gl46.init(&self.common, &self.font_service, configured_gpu),
        },
    };
}

test "OpenGL startup in RDP offers an explicit D3D11 fallback" {
    const fallback = recommendStartupFallback(.opengl, true).?;
    try std.testing.expectEqual(Config.RendererBackend.opengl, fallback.configured);
    try std.testing.expectEqual(StartupFallback.Reason.remote_session, fallback.reason);
    try std.testing.expectEqual(
        Config.RendererBackend.d3d11,
        fallback.selectedBackend(true).?,
    );
    try std.testing.expectEqual(@as(?Config.RendererBackend, null), fallback.selectedBackend(false));
}

test "compatible renderer environments do not offer a fallback" {
    try std.testing.expectEqual(@as(?StartupFallback, null), recommendStartupFallback(.opengl, false));
    try std.testing.expectEqual(@as(?StartupFallback, null), recommendStartupFallback(.d3d11, true));
    try std.testing.expectEqual(@as(?StartupFallback, null), recommendStartupFallback(.d3d12, true));
}

pub fn cellSizeForDpi(self: *Renderer, dpi: u32) win32.SIZE {
    return self.font_service.cellSizeForDpi(dpi);
}

pub fn tabBarHeightForDpi(self: *Renderer, dpi: u32) i32 {
    return self.font_service.tabBarHeightForDpi(dpi);
}

pub fn updateDpi(self: *Renderer, dpi: u32) void {
    if (self.font_service.updateDpi(dpi)) {
        switch (self.backend) {
            inline else => |*backend| backend.onFontStateChanged(),
        }
    }
}

pub fn updateFont(self: *Renderer, font_config: FontConfig) void {
    self.font_service.updateFont(font_config);
    switch (self.backend) {
        inline else => |*backend| backend.onFontStateChanged(),
    }
}

pub fn deinit(self: *Renderer) void {
    switch (self.backend) {
        inline else => |*backend| backend.deinit(),
    }
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
    switch (self.backend) {
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
    return switch (self.backend) {
        inline else => |*backend| backend.applyGlyphResult(result),
    };
}

pub fn reloadBackgroundImage(
    self: *Renderer,
    gpa: std.mem.Allocator,
    cfg: *const Config,
    hwnd: win32.HWND,
) void {
    switch (self.backend) {
        inline else => |*backend| backend.reloadBackgroundImage(gpa, cfg, hwnd),
    }
}

pub fn applyDecodedBackgroundImage(self: *Renderer, result: *const BgImageDecoded) void {
    switch (self.backend) {
        inline else => |*backend| backend.applyDecodedBackgroundImage(result),
    }
}

pub fn releaseKittyImagesForTab(self: *Renderer, tab_id: types.TabId) void {
    switch (self.backend) {
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
