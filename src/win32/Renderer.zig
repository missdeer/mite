const Renderer = @This();

const std = @import("std");
const vt = @import("vt");
const win32 = @import("win32").everything;

const Config = @import("../Config.zig");
const d3d11 = @import("d3d11.zig");
const FontService = @import("FontService.zig");
const types = @import("types.zig");

// Compiled and tested, but not a `RendererBackend` variant: fulfilling the
// whole facade contract is the precondition for being selectable, and the
// D3D12 skeleton cannot do that yet.
pub const d3d12 = @import("d3d12.zig");

pub const RendererCommon = @import("RendererCommon.zig");

pub const BgImageDecoded = d3d11.BgImageDecoded;
pub const RasterResult = FontService.RasterResult;
pub const FontConfig = FontService.FontConfig;
pub const scrollbarWidth = d3d11.scrollbarWidth;
pub const default_primary_font_family = FontService.default_primary_font_family;
pub const default_font_size_pt = FontService.default_font_size_pt;

pub const RendererBackend = union(enum) {
    d3d11: d3d11,
};

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
) void {
    self.font_service = FontService.init(
        &self.common,
        dpi,
        font_config,
        font_ligatures,
        configured_gpu,
    );
    self.backend = .{
        .d3d11 = d3d11.init(&self.common, &self.font_service, configured_gpu),
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

test "unimplemented renderer backends are not selectable" {
    const fields = @typeInfo(RendererBackend).@"union".fields;
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("d3d11", fields[0].name);
}

test "d3d12 is built and verified without being reachable through backend selection" {
    // The facade dispatches every contract method to whichever variant is
    // selected, so a variant that cannot draw would be a selectable broken
    // terminal. Presence here is what keeps the skeleton honest: compiled and
    // covered by tests, but impossible to select.
    try std.testing.expect(@hasDecl(d3d12, "Skeleton"));
    inline for (@typeInfo(RendererBackend).@"union".fields) |field| {
        try std.testing.expect(!std.mem.eql(u8, field.name, "d3d12"));
    }
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
