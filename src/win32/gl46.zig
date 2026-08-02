//! OpenGL 4.6 baseline renderer.
//!
//! The backend deliberately stops at the M5a boundary: WGL owns the window
//! presentation path and the font service hands pixels over through CPU
//! memory. DirectComposition and D3D/OpenGL interop belong to M5b.

const Gl46Renderer = @This();

const std = @import("std");
const vt = @import("vt");
const win32 = @import("win32").everything;

const Config = @import("../Config.zig");
const FontService = @import("FontService.zig");
const GlyphIndexCache = @import("GlyphIndexCache.zig");
const RendererCommon = @import("RendererCommon.zig");
const shared = @import("shared.zig");
const types = @import("types.zig");

const bg_image = @import("d3d11/background_image.zig");
const cell_buffer = @import("d3d11/cell_buffer.zig");
const glyph_mod = @import("d3d11/glyph.zig");
const gpu = @import("d3d11/gpu.zig");
const grid = @import("d3d11/grid.zig");
const kitty_image_mod = @import("d3d11/kitty_images.zig");
const tabbar_paint = @import("d3d11/tabbar_paint.zig");
const shader_assets = @import("shader_assets.zig");
const gl = @import("gl46/loader.zig");

const CellXY = gpu.CellXY;
const shader = gpu.shader;
const log = std.log.scoped(.gl46);

pub const BgImageDecoded = bg_image.BgImageDecoded;
pub const RasterResult = FontService.RasterResult;
pub const scrollbarWidth = gpu.scrollbarWidth;
pub const glyph_handoff: shared.GlyphHandoff = .cpu_pixels;

const frame_count = 3;
const map_flags = gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT | gl.MAP_COHERENT_BIT;

const WglCreateContextAttribs = *const fn (
    win32.HDC,
    ?win32.HGLRC,
    [*:0]const i32,
) callconv(.winapi) ?win32.HGLRC;
const WglSwapInterval = *const fn (i32) callconv(.winapi) win32.BOOL;

const WGL_CONTEXT_MAJOR_VERSION_ARB = 0x2091;
const WGL_CONTEXT_MINOR_VERSION_ARB = 0x2092;
const WGL_CONTEXT_FLAGS_ARB = 0x2094;
const WGL_CONTEXT_PROFILE_MASK_ARB = 0x9126;
const WGL_CONTEXT_CORE_PROFILE_BIT_ARB = 0x00000001;
const WGL_CONTEXT_DEBUG_BIT_ARB = 0x00000001;

const DebugStats = struct {
    rows_uploaded: u64 = 0,
    rows_skipped: u64 = 0,
};

pub const KittyImage = struct {
    texture: gl.uint,

    pub fn release(self: *KittyImage) void {
        gl.DeleteTextures(1, @ptrCast(&self.texture));
        self.* = undefined;
    }
};

pub const BackgroundImage = struct {
    texture: gl.uint = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,

    pub fn loaded(self: BackgroundImage) bool {
        return self.texture != 0;
    }

    pub fn release(self: *BackgroundImage) void {
        if (self.texture != 0) gl.DeleteTextures(1, @ptrCast(&self.texture));
        self.* = .{};
    }
};

const MappedBuffer = struct {
    name: gl.uint = 0,
    bytes: ?[*]u8 = null,
    size: usize = 0,

    fn create(size: usize) MappedBuffer {
        var name: gl.uint = 0;
        gl.CreateBuffers(1, @ptrCast(&name));
        if (name == 0) fatal("glCreateBuffers returned zero");
        gl.NamedBufferStorage(name, @intCast(size), null, map_flags);
        const mapped = gl.MapNamedBufferRange(name, 0, @intCast(size), map_flags) orelse
            fatal("persistent buffer mapping failed");
        return .{ .name = name, .bytes = @ptrCast(mapped), .size = size };
    }

    fn release(self: *MappedBuffer) void {
        if (self.name != 0) {
            _ = gl.UnmapNamedBuffer(self.name);
            gl.DeleteBuffers(1, @ptrCast(&self.name));
        }
        self.* = .{};
    }
};

// Shared-layer state.
common: *RendererCommon,
font_service: *FontService,
shadow_cells: []shader.Cell = &.{},
glyph_cache_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
glyph_cache: ?GlyphIndexCache = null,
glyph_cache_cell_size: ?CellXY = null,
cache_gen: u32 = 0,
grid_force_full: bool = true,
last_const_snapshot: grid.ConfigSnapshot = .{},
stats: DebugStats = .{},
diag_rows_uploaded: u64 = 0,
diag_rows_skipped: u64 = 0,

background_image: BackgroundImage = .{},
bg_image_path: []const u8 = &.{},
bg_image_opacity: f32 = 1.0,
bg_image_position: Config.BackgroundImagePosition = .center,
bg_image_fit: Config.BackgroundImageFit = .contain,
bg_image_repeat: bool = false,
bg_image_req_id: u32 = 0,
kitty_images: kitty_image_mod.Cache(KittyImage) = .{},

// WGL/OpenGL state is created lazily once the HWND exists.
initialized: bool = false,
hwnd: ?win32.HWND = null,
dc: ?win32.HDC = null,
context: ?win32.HGLRC = null,
procs: gl.ProcTable = undefined,

grid_program: gl.uint = 0,
image_program: gl.uint = 0,
vao: gl.uint = 0,
sampler: gl.uint = 0,

grid_ubo: MappedBuffer = .{},
grid_ubo_stride: usize = 0,
image_ubo: MappedBuffer = .{},
image_ubo_stride: usize = 0,
image_ubo_capacity: usize = 0,

cells: MappedBuffer = .{},
cells_count: u32 = 0,
cells_stride: usize = 0,
storage_alignment: usize = 1,

atlas: gl.uint = 0,
atlas_size: ?CellXY = null,
tabbar_texture: gl.uint = 0,
tabbar_size: win32.SIZE = .{ .cx = 0, .cy = 0 },

fences: [frame_count]?*gl.sync = @splat(null),
frame_slot: usize = frame_count - 1,
last_frame_slot: ?usize = null,

pub fn init(
    common: *RendererCommon,
    font_service: *FontService,
    configured_gpu: ?[]const u8,
) Gl46Renderer {
    if (configured_gpu) |name| std.debug.panic(
        "renderer = opengl: gpu override '{s}' cannot be honored by the M5a WGL path; " ++
            "remove gpu or select a D3D backend",
        .{name},
    );
    return .{ .common = common, .font_service = font_service };
}

pub fn deinit(self: *Gl46Renderer) void {
    if (self.initialized) {
        if (win32.wglMakeCurrent(self.dc.?, self.context.?) == 0) {
            fatal("wglMakeCurrent during teardown failed");
        }
        gl.makeProcTableCurrent(&self.procs);
        gl.Finish();
        self.kitty_images.deinit(std.heap.page_allocator);
        self.background_image.release();
        self.releaseGlyphState();

        if (self.tabbar_texture != 0) gl.DeleteTextures(1, @ptrCast(&self.tabbar_texture));
        if (self.atlas != 0) gl.DeleteTextures(1, @ptrCast(&self.atlas));
        self.cells.release();
        self.image_ubo.release();
        self.grid_ubo.release();
        if (self.sampler != 0) gl.DeleteSamplers(1, @ptrCast(&self.sampler));
        if (self.vao != 0) gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
        if (self.image_program != 0) gl.DeleteProgram(self.image_program);
        if (self.grid_program != 0) gl.DeleteProgram(self.grid_program);
        for (&self.fences) |*fence| {
            if (fence.*) |f| gl.DeleteSync(f);
            fence.* = null;
        }

        gl.makeProcTableCurrent(null);
        _ = win32.wglMakeCurrent(null, null);
        if (self.context) |context| _ = win32.wglDeleteContext(context);
        if (self.dc) |dc| {
            if (self.hwnd) |hwnd| _ = win32.ReleaseDC(hwnd, dc);
        }
    } else {
        self.kitty_images.deinit(std.heap.page_allocator);
        self.releaseGlyphState();
    }
    self.* = undefined;
}

fn releaseGlyphState(self: *Gl46Renderer) void {
    if (self.glyph_cache) |*cache| {
        cache.deinit(self.glyph_cache_arena.allocator());
        self.glyph_cache = null;
    }
    _ = self.glyph_cache_arena.reset(.free_all);
    std.heap.page_allocator.free(self.shadow_cells);
    self.shadow_cells = &.{};
}

pub fn onFontStateChanged(self: *Gl46Renderer) void {
    self.cache_gen +%= 1;
    if (self.glyph_cache) |*cache| {
        cache.deinit(self.glyph_cache_arena.allocator());
        self.glyph_cache = null;
    }
    _ = self.glyph_cache_arena.reset(.free_all);
    self.glyph_cache_cell_size = null;
    self.grid_force_full = true;
}

fn ensureInitialized(self: *Gl46Renderer, hwnd: win32.HWND) void {
    if (self.initialized) {
        if (self.hwnd != hwnd) fatal("the WGL context was asked to move to another window");
        gl.makeProcTableCurrent(&self.procs);
        return;
    }
    if (win32.GetSystemMetrics(win32.SM_REMOTESESSION) != 0) std.debug.panic(
        "renderer = opengl: RDP is outside the OpenGL 4.6 baseline because Windows " ++
            "normally exposes only the GDI Generic 1.1 implementation",
        .{},
    );

    const dc = win32.GetDC(hwnd) orelse fatal("GetDC failed");
    errdefer _ = win32.ReleaseDC(hwnd, dc);

    var pfd = std.mem.zeroes(win32.PIXELFORMATDESCRIPTOR);
    pfd.nSize = @sizeOf(win32.PIXELFORMATDESCRIPTOR);
    pfd.nVersion = 1;
    pfd.dwFlags = .{
        .DRAW_TO_WINDOW = 1,
        .SUPPORT_OPENGL = 1,
        .DOUBLEBUFFER = 1,
        .SUPPORT_COMPOSITION = 1,
    };
    pfd.iPixelType = .RGBA;
    pfd.cColorBits = 32;
    pfd.cAlphaBits = 8;
    pfd.iLayerType = .MAIN_PLANE;
    const pixel_format = win32.ChoosePixelFormat(dc, &pfd);
    if (pixel_format == 0) fatal("ChoosePixelFormat found no composited RGBA format");
    if (win32.SetPixelFormat(dc, pixel_format, &pfd) == 0) fatal("SetPixelFormat failed");

    const bootstrap = win32.wglCreateContext(dc) orelse fatal("legacy WGL bootstrap context creation failed");
    defer _ = win32.wglDeleteContext(bootstrap);
    if (win32.wglMakeCurrent(dc, bootstrap) == 0) fatal("legacy WGL bootstrap context could not be made current");

    const create_context: WglCreateContextAttribs = procAddress(
        WglCreateContextAttribs,
        "wglCreateContextAttribsARB",
    ) orelse fatal("WGL_ARB_create_context is unavailable");
    const swap_interval: WglSwapInterval = procAddress(
        WglSwapInterval,
        "wglSwapIntervalEXT",
    ) orelse fatal("WGL_EXT_swap_control is unavailable");

    const context_flags: i32 = if (@import("builtin").mode == .Debug)
        WGL_CONTEXT_DEBUG_BIT_ARB
    else
        0;
    const attribs = [_:0]i32{
        WGL_CONTEXT_MAJOR_VERSION_ARB,
        4,
        WGL_CONTEXT_MINOR_VERSION_ARB,
        6,
        WGL_CONTEXT_FLAGS_ARB,
        context_flags,
        WGL_CONTEXT_PROFILE_MASK_ARB,
        WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
        0,
    };
    const context = create_context(dc, null, &attribs) orelse
        fatal("the driver rejected an OpenGL 4.6 core context");
    if (win32.wglMakeCurrent(dc, context) == 0) fatal("OpenGL 4.6 context could not be made current");

    const opengl_module = win32.GetModuleHandleW(win32.L("opengl32.dll")) orelse
        fatal("opengl32.dll is not loaded");
    if (!self.procs.init(ProcLoader{ .module = opengl_module }))
        fatal("the OpenGL 4.6 core procedure table is incomplete");
    gl.makeProcTableCurrent(&self.procs);

    var major: gl.int = 0;
    var minor: gl.int = 0;
    gl.GetIntegerv(gl.MAJOR_VERSION, @ptrCast(&major));
    gl.GetIntegerv(gl.MINOR_VERSION, @ptrCast(&minor));
    if (major < 4 or (major == 4 and minor < 6)) std.debug.panic(
        "renderer = opengl: driver exposed OpenGL {d}.{d}, but 4.6 is required for " ++
            "core SPIR-V ingestion",
        .{ major, minor },
    );

    gl.Enable(gl.DEBUG_OUTPUT);
    gl.Enable(gl.DEBUG_OUTPUT_SYNCHRONOUS);
    gl.DebugMessageCallback(debugMessage, null);
    if (swap_interval(1) == 0) fatal("wglSwapIntervalEXT(1) failed");
    gl.ClipControl(gl.UPPER_LEFT, gl.ZERO_TO_ONE);
    gl.Enable(gl.FRAMEBUFFER_SRGB);
    gl.Enable(gl.BLEND);
    gl.BlendFuncSeparate(gl.ONE, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
    gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1);

    var storage_alignment: gl.int = 1;
    var uniform_alignment: gl.int = 1;
    gl.GetIntegerv(gl.SHADER_STORAGE_BUFFER_OFFSET_ALIGNMENT, @ptrCast(&storage_alignment));
    gl.GetIntegerv(gl.UNIFORM_BUFFER_OFFSET_ALIGNMENT, @ptrCast(&uniform_alignment));
    self.storage_alignment = @intCast(@max(1, storage_alignment));
    self.grid_ubo_stride = alignForward(@sizeOf(shader.GridConfig), @intCast(@max(1, uniform_alignment)));
    self.image_ubo_stride = alignForward(@sizeOf(kitty_image_mod.ImageConfig), @intCast(@max(1, uniform_alignment)));
    self.grid_ubo = MappedBuffer.create(self.grid_ubo_stride * frame_count);
    self.ensureImageUboCapacity(1);

    self.grid_program = createProgram(shader_assets.vertex.spirv, "VertexMain", shader_assets.pixel.spirv, "PixelMain");
    self.image_program = createProgram(shader_assets.vertex.spirv, "VertexMain", shader_assets.image_pixel.spirv, "ImagePixelMain");

    gl.CreateVertexArrays(1, @ptrCast(&self.vao));
    gl.BindVertexArray(self.vao);
    gl.CreateSamplers(1, @ptrCast(&self.sampler));
    gl.SamplerParameteri(self.sampler, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.SamplerParameteri(self.sampler, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.SamplerParameteri(self.sampler, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.SamplerParameteri(self.sampler, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    inline for (.{ 2, 3, 5 }) |unit| gl.BindSampler(unit, self.sampler);

    self.hwnd = hwnd;
    self.dc = dc;
    self.context = context;
    self.initialized = true;
    log.info(
        "OpenGL {d}.{d} baseline active: shared SPIR-V, swap interval 1, {d} completion slots",
        .{ major, minor, frame_count },
    );
}

fn debugMessage(
    source: gl.@"enum",
    message_type: gl.@"enum",
    id: gl.uint,
    severity: gl.@"enum",
    length: gl.sizei,
    message: [*:0]const gl.char,
    user_param: ?*const anyopaque,
) callconv(gl.APIENTRY) void {
    _ = source;
    _ = message_type;
    _ = id;
    _ = severity;
    _ = length;
    _ = user_param;
    win32.OutputDebugStringA(message);
}

const ProcLoader = struct {
    module: win32.HINSTANCE,

    pub fn getProcAddress(self: ProcLoader, name: [*:0]const u8) ?gl.PROC {
        if (win32.wglGetProcAddress(name)) |candidate| {
            const raw = @intFromPtr(candidate);
            if (raw > 3 and raw != std.math.maxInt(usize)) return @ptrCast(candidate);
        }
        const candidate = win32.GetProcAddress(self.module, name) orelse return null;
        return @ptrCast(candidate);
    }
};

fn procAddress(comptime T: type, name: [*:0]const u8) ?T {
    const candidate = win32.wglGetProcAddress(name) orelse return null;
    const raw = @intFromPtr(candidate);
    if (raw <= 3 or raw == std.math.maxInt(usize)) return null;
    return @ptrCast(candidate);
}

fn createProgram(
    vertex_spirv: []const u8,
    vertex_entry: [*:0]const u8,
    pixel_spirv: []const u8,
    pixel_entry: [*:0]const u8,
) gl.uint {
    const vertex = createShader(gl.VERTEX_SHADER, vertex_spirv, vertex_entry);
    defer gl.DeleteShader(vertex);
    const pixel = createShader(gl.FRAGMENT_SHADER, pixel_spirv, pixel_entry);
    defer gl.DeleteShader(pixel);

    const program = gl.CreateProgram();
    if (program == 0) fatal("glCreateProgram returned zero");
    gl.AttachShader(program, vertex);
    gl.AttachShader(program, pixel);
    gl.LinkProgram(program);
    var linked: gl.int = 0;
    gl.GetProgramiv(program, gl.LINK_STATUS, @ptrCast(&linked));
    if (linked == 0) {
        var log_buf: [2048]u8 = undefined;
        var len: gl.sizei = 0;
        gl.GetProgramInfoLog(program, @intCast(log_buf.len), @ptrCast(&len), @ptrCast(&log_buf));
        std.debug.panic("renderer = opengl: SPIR-V program link failed: {s}", .{log_buf[0..@intCast(@max(0, len))]});
    }
    return program;
}

fn createShader(kind: gl.@"enum", spirv: []const u8, entry: [*:0]const u8) gl.uint {
    const object = gl.CreateShader(kind);
    if (object == 0) fatal("glCreateShader returned zero");
    var shader_name = object;
    gl.ShaderBinary(1, @ptrCast(&shader_name), gl.SHADER_BINARY_FORMAT_SPIR_V, spirv.ptr, @intCast(spirv.len));
    var unused = [_]gl.uint{0};
    gl.SpecializeShader(object, entry, 0, &unused, &unused);
    var compiled: gl.int = 0;
    gl.GetShaderiv(object, gl.COMPILE_STATUS, @ptrCast(&compiled));
    if (compiled == 0) {
        var log_buf: [2048]u8 = undefined;
        var len: gl.sizei = 0;
        gl.GetShaderInfoLog(object, @intCast(log_buf.len), @ptrCast(&len), @ptrCast(&log_buf));
        std.debug.panic("renderer = opengl: SPIR-V specialization failed: {s}", .{log_buf[0..@intCast(@max(0, len))]});
    }
    return object;
}

fn alignForward(value: usize, alignment: usize) usize {
    return std.mem.alignForward(usize, value, std.math.ceilPowerOfTwoAssert(usize, alignment));
}

fn fatal(message: []const u8) noreturn {
    std.debug.panic("renderer = opengl: {s}", .{message});
}

fn beginFrame(self: *Gl46Renderer) void {
    const next = (self.frame_slot + 1) % frame_count;
    self.waitForSlot(next);
    if (self.cells.bytes) |mapped| if (self.last_frame_slot) |previous| {
        const used = @as(usize, self.cells_count) * @sizeOf(shader.Cell);
        if (used != 0) {
            const src = mapped[previous * self.cells_stride ..][0..used];
            const dst = mapped[next * self.cells_stride ..][0..used];
            @memcpy(dst, src);
        }
    };
    self.frame_slot = next;
    self.last_frame_slot = next;
}

fn waitForSlot(self: *Gl46Renderer, slot: usize) void {
    const fence = self.fences[slot] orelse return;
    var attempts: u32 = 0;
    while (true) : (attempts += 1) {
        const result = gl.ClientWaitSync(fence, gl.SYNC_FLUSH_COMMANDS_BIT, 100_000_000);
        if (result == gl.ALREADY_SIGNALED or result == gl.CONDITION_SATISFIED) break;
        if (result == gl.WAIT_FAILED) fatal("glClientWaitSync failed");
        if (attempts >= 99) fatal("GPU completion did not arrive within 10 seconds");
    }
    gl.DeleteSync(fence);
    self.fences[slot] = null;
}

fn finishFrame(self: *Gl46Renderer) void {
    self.fences[self.frame_slot] = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0) orelse
        fatal("glFenceSync failed");
    if (win32.SwapBuffers(self.dc.?) == 0) fatal("SwapBuffers failed");
}

pub fn cellsResize(self: *Gl46Renderer, count: u32) bool {
    if (count == self.cells_count and self.cells.name != 0) return false;
    self.cells.release();
    self.cells_count = count;
    const used = @max(@sizeOf(shader.Cell), @as(usize, count) * @sizeOf(shader.Cell));
    self.cells_stride = alignForward(used, self.storage_alignment);
    self.cells = MappedBuffer.create(self.cells_stride * frame_count);
    @memset(self.cells.bytes.?[0 .. self.cells_stride * frame_count], 0);
    // buildAndUpload performs a mandatory full upload after recreation. The
    // current slice is therefore the authoritative source copied into the
    // next slot; clearing this would make unchanged rows zero on frame two.
    self.last_frame_slot = self.frame_slot;
    return true;
}

pub fn cellsUpload(self: *Gl46Renderer, first_cell: u32, cells: []const shader.Cell) void {
    const bytes = std.mem.sliceAsBytes(cells);
    const offset = self.frame_slot * self.cells_stride + @as(usize, first_cell) * @sizeOf(shader.Cell);
    @memcpy(self.cells.bytes.?[offset..][0..bytes.len], bytes);
}

pub fn atlasEnsure(self: *Gl46Renderer, tex_pixel: CellXY) bool {
    if (self.atlas_size) |size| if (size.eql(tex_pixel)) return true;
    if (self.atlas != 0) gl.DeleteTextures(1, @ptrCast(&self.atlas));
    self.atlas = createTexture(tex_pixel.x, tex_pixel.y, gl.RGBA8);
    self.atlas_size = tex_pixel;
    return false;
}

pub fn atlasWriteCpu(
    self: *Gl46Renderer,
    dst_coord: CellXY,
    region: CellXY,
    src_ptr: [*]const u8,
    src_row_pitch: u32,
) void {
    if (self.atlas == 0) return;
    gl.PixelStorei(gl.UNPACK_ROW_LENGTH, @intCast(src_row_pitch / 4));
    gl.TextureSubImage2D(
        self.atlas,
        0,
        @intCast(dst_coord.x),
        @intCast(dst_coord.y),
        @intCast(region.x),
        @intCast(region.y),
        gl.BGRA,
        gl.UNSIGNED_BYTE,
        src_ptr,
    );
    gl.PixelStorei(gl.UNPACK_ROW_LENGTH, 0);
}

pub fn atlasClear(self: *Gl46Renderer, dst_coord: CellXY) void {
    const cs = self.font_service.cell_size_xy;
    const row_bytes: usize = @as(usize, cs.x) * 4;
    const zeros = std.heap.page_allocator.alloc(u8, row_bytes * cs.y) catch return;
    defer std.heap.page_allocator.free(zeros);
    @memset(zeros, 0);
    self.atlasWriteCpu(dst_coord, cs, zeros.ptr, @intCast(row_bytes));
}

pub fn atlasCopyStaging(
    self: *Gl46Renderer,
    staging: *gpu.StagingTexture.Cached,
    first: ?gpu.AtlasCopy,
    second: ?gpu.AtlasCopy,
) void {
    _ = .{ self, staging, first, second };
    unreachable;
}

pub fn backgroundImageRelease(self: *Gl46Renderer) void {
    self.background_image.release();
}

pub fn backgroundImageUpload(self: *Gl46Renderer, decoded: gpu.DecodedBackground) void {
    self.backgroundImageRelease();
    const texture = createTexture(decoded.w, decoded.h, gl.RGBA8);
    gl.TextureSubImage2D(
        texture,
        0,
        0,
        0,
        @intCast(decoded.w),
        @intCast(decoded.h),
        gl.BGRA,
        gl.UNSIGNED_BYTE,
        decoded.pixels.ptr,
    );
    self.background_image = .{ .texture = texture, .src_w = decoded.w, .src_h = decoded.h };
}

pub fn kittyImageUpload(
    self: *Gl46Renderer,
    width: u32,
    height: u32,
    rgba: []const u8,
) ?KittyImage {
    _ = self;
    const texture = createTexture(width, height, gl.RGBA8);
    gl.TextureSubImage2D(
        texture,
        0,
        0,
        0,
        @intCast(width),
        @intCast(height),
        gl.RGBA,
        gl.UNSIGNED_BYTE,
        rgba.ptr,
    );
    return .{ .texture = texture };
}

fn createTexture(width: u32, height: u32, internal_format: gl.@"enum") gl.uint {
    var texture: gl.uint = 0;
    gl.CreateTextures(gl.TEXTURE_2D, 1, @ptrCast(&texture));
    if (texture == 0) fatal("glCreateTextures returned zero");
    gl.TextureStorage2D(texture, 1, internal_format, @intCast(width), @intCast(height));
    gl.TextureParameteri(texture, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.TextureParameteri(texture, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.TextureParameteri(texture, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.TextureParameteri(texture, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    return texture;
}

pub fn render(
    self: *Gl46Renderer,
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
    if (remote_session) fatal("an RDP session entered while the OpenGL backend was active");
    self.ensureInitialized(hwnd);
    const prepared = self.prepareFrame(hwnd, term, mouse_in_scrollbar) orelse return;

    if (self.kitty_images.sync(std.heap.page_allocator, self, tab_id, term)) {
        self.grid_force_full = true;
    }
    const build = cell_buffer.buildAndUpload(
        self,
        term,
        prepared.shader_col,
        prepared.term_shader_row,
        prepared.tex_cell_count,
        prepared.atlas,
        resizing,
        selection_fade,
        cursor_text,
        selection_bg,
        selection_fg,
        background_opacity,
        url_highlight,
    );
    if (build.has_blink) {
        _ = win32.SetTimer(hwnd, types.TIMER_TEXT_BLINK, 250, null);
    } else {
        _ = win32.KillTimer(hwnd, types.TIMER_TEXT_BLINK);
    }

    self.drawFrame(prepared, tabbar);
    self.finishFrame();
}

const PreparedFrame = struct {
    client_w: u32,
    client_h: u32,
    cs: CellXY,
    shader_col: u32,
    tab_bar_h: u32,
    term_pixel_h: u32,
    term_shader_row: u32,
    atlas: gpu.AtlasFrame,
    tex_cell_count: CellXY,
    config: shader.GridConfig,
};

fn prepareFrame(
    self: *Gl46Renderer,
    hwnd: win32.HWND,
    term: *vt.Terminal,
    mouse_in_scrollbar: bool,
) ?PreparedFrame {
    const sz = win32.getClientSize(hwnd);
    const client_w: u32 = @intCast(sz.cx);
    const client_h: u32 = @intCast(sz.cy);
    if (client_w == 0 or client_h == 0) return null;
    self.beginFrame();

    const cs = self.font_service.cell_size_xy;
    const sb_px: u32 = scrollbarWidth(win32.dpiFromHwnd(hwnd));
    const grid_w: u32 = client_w -| sb_px;
    const shader_col: u32 = @divTrunc(grid_w + cs.x - 1, cs.x);
    const tab_bar_h: u32 = @intCast(@max(0, self.common.tab_bar_height));
    const term_pixel_h: u32 = client_h -| tab_bar_h;
    const term_shader_row: u32 = @divTrunc(term_pixel_h + cs.y - 1, cs.y);
    if (shader_col > cell_buffer.max_shader_col) return null;

    const atlas = glyph_mod.setupGlyphAtlas(self);
    const tex_cell_count = atlas.tex_cell_count;

    var sb_geom: struct { x: f32, y: f32, w: f32, h: f32 } = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    const sb = term.screens.active.pages.scrollbar();
    const show = sb.total > sb.len and (!term.screens.active.viewportIsBottom() or mouse_in_scrollbar);
    if (show) {
        const origin_y: f32 = @floatFromInt(tab_bar_h);
        const win_h: f32 = @floatFromInt(client_h -| tab_bar_h);
        const track_h = @max(20.0, @as(f32, @floatFromInt(sb.len)) /
            @as(f32, @floatFromInt(sb.total)) * win_h);
        const max_offset = sb.total - sb.len;
        const track_y = origin_y + @as(f32, @floatFromInt(sb.offset)) /
            @as(f32, @floatFromInt(max_offset)) * (win_h - track_h);
        sb_geom = .{
            .x = @floatFromInt(grid_w),
            .y = track_y,
            .w = @floatFromInt(sb_px),
            .h = track_h,
        };
    }

    const snapshot: grid.ConfigSnapshot = .{
        .cell_w = cs.x,
        .cell_h = cs.y,
        .col_count = shader_col,
        .row_count = term_shader_row,
        .cells_per_row = tex_cell_count.x,
        .tab_bar_height = tab_bar_h,
        .scrollbar_x = sb_geom.x,
        .scrollbar_y = sb_geom.y,
        .scrollbar_width = sb_geom.w,
        .scrollbar_height = sb_geom.h,
    };
    if (!snapshot.eql(self.last_const_snapshot)) {
        self.grid_force_full = true;
        self.last_const_snapshot = snapshot;
    }

    var config: shader.GridConfig = .{
        .cell_size = .{ cs.x, cs.y },
        .col_count = shader_col,
        .row_count = term_shader_row,
        .scrollbar_y = sb_geom.y,
        .scrollbar_height = sb_geom.h,
        .scrollbar_x = sb_geom.x,
        .scrollbar_width = sb_geom.w,
        .cells_per_row = tex_cell_count.x,
        .tab_bar_height = tab_bar_h,
    };
    if (self.background_image.loaded()) {
        config.bg_image_flags = 1 | @as(u32, if (self.bg_image_repeat) 2 else 0);
        config.bg_image_opacity = self.bg_image_opacity;
        config.bg_image_dest = bg_image.computeDest(
            self,
            @floatFromInt(shader_col * cs.x),
            @floatFromInt(term_shader_row * cs.y),
        );
    }

    return .{
        .client_w = client_w,
        .client_h = client_h,
        .cs = cs,
        .shader_col = shader_col,
        .tab_bar_h = tab_bar_h,
        .term_pixel_h = term_pixel_h,
        .term_shader_row = term_shader_row,
        .atlas = atlas,
        .tex_cell_count = tex_cell_count,
        .config = config,
    };
}

fn drawFrame(self: *Gl46Renderer, prepared: PreparedFrame, tabbar: types.TabBarDraw) void {
    gl.BindVertexArray(self.vao);
    gl.MemoryBarrier(gl.CLIENT_MAPPED_BUFFER_BARRIER_BIT);

    const grid_offset = self.frame_slot * self.grid_ubo_stride;
    @memcpy(
        self.grid_ubo.bytes.?[grid_offset..][0..@sizeOf(shader.GridConfig)],
        std.mem.asBytes(&prepared.config),
    );
    gl.MemoryBarrier(gl.CLIENT_MAPPED_BUFFER_BARRIER_BIT);
    gl.BindBufferRange(
        gl.UNIFORM_BUFFER,
        0,
        self.grid_ubo.name,
        @intCast(grid_offset),
        @sizeOf(shader.GridConfig),
    );
    gl.BindBufferRange(
        gl.SHADER_STORAGE_BUFFER,
        1,
        self.cells.name,
        @intCast(self.frame_slot * self.cells_stride),
        @intCast(@as(usize, self.cells_count) * @sizeOf(shader.Cell)),
    );
    gl.BindTextureUnit(2, self.atlas);
    gl.BindTextureUnit(3, self.background_image.texture);
    gl.Viewport(0, @intCast(prepared.tab_bar_h), @intCast(prepared.client_w), @intCast(prepared.term_pixel_h));
    gl.UseProgram(self.grid_program);
    gl.DrawArrays(gl.TRIANGLE_STRIP, 0, 4);

    const visible_images = self.countVisiblePlacements();
    self.ensureImageUboCapacity(visible_images + 1);
    var config_index: usize = 0;
    gl.Viewport(0, 0, @intCast(prepared.client_w), @intCast(prepared.client_h));
    gl.UseProgram(self.image_program);
    for (self.kitty_images.placements.items) |placement| {
        if (placement.z < 0) continue;
        const entry = self.kitty_images.images.get(.{
            .tab_id = self.kitty_images.last_tab_id,
            .image_id = placement.image_id,
        }) orelse continue;
        var config: kitty_image_mod.ImageConfig = .{
            .dest = .{
                @floatFromInt(@as(i64, placement.x) * prepared.cs.x + placement.cell_offset_x),
                @floatFromInt(@as(i64, placement.y) * prepared.cs.y + placement.cell_offset_y),
                @floatFromInt(placement.width),
                @floatFromInt(placement.height),
            },
            .source = .{
                @floatFromInt(placement.source_x),
                @floatFromInt(placement.source_y),
                @floatFromInt(placement.source_width),
                @floatFromInt(placement.source_height),
            },
            .image_size = .{ @floatFromInt(entry.width), @floatFromInt(entry.height) },
            .tab_bar_height = @floatFromInt(prepared.tab_bar_h),
        };
        self.drawImageConfig(config_index, &config, entry.image.texture);
        config_index += 1;
    }

    if (prepared.tab_bar_h != 0) {
        const band = self.font_service.cpuBand(prepared.client_w, prepared.tab_bar_h);
        tabbar_paint.paint(
            band.render_target,
            band.brush,
            &self.font_service.dwrite_factory.IDWriteFactory,
            self.font_service.tabbar_text_format,
            self.font_service.tabbar_trimming_sign,
            tabbar,
            prepared.cs.x,
            prepared.tab_bar_h,
        );
        const pixels = band.readPixels();
        self.ensureTabbarTexture(prepared.client_w, prepared.tab_bar_h);
        gl.TextureSubImage2D(
            self.tabbar_texture,
            0,
            0,
            0,
            @intCast(prepared.client_w),
            @intCast(prepared.tab_bar_h),
            gl.BGRA,
            gl.UNSIGNED_BYTE,
            pixels.ptr,
        );
        var config: kitty_image_mod.ImageConfig = .{
            .dest = .{ 0, 0, @floatFromInt(prepared.client_w), @floatFromInt(prepared.tab_bar_h) },
            .source = .{ 0, 0, @floatFromInt(prepared.client_w), @floatFromInt(prepared.tab_bar_h) },
            .image_size = .{ @floatFromInt(prepared.client_w), @floatFromInt(prepared.tab_bar_h) },
            .tab_bar_height = 0,
        };
        self.drawImageConfig(config_index, &config, self.tabbar_texture);
    }
    self.grid_force_full = false;
}

fn countVisiblePlacements(self: *Gl46Renderer) usize {
    var count: usize = 0;
    for (self.kitty_images.placements.items) |placement| {
        if (placement.z >= 0) count += 1;
    }
    return count;
}

fn ensureImageUboCapacity(self: *Gl46Renderer, wanted: usize) void {
    if (wanted <= self.image_ubo_capacity) return;
    self.image_ubo.release();
    self.image_ubo_capacity = wanted;
    self.image_ubo = MappedBuffer.create(self.image_ubo_stride * wanted * frame_count);
}

fn drawImageConfig(
    self: *Gl46Renderer,
    index: usize,
    config: *const kitty_image_mod.ImageConfig,
    texture: gl.uint,
) void {
    const offset = (self.frame_slot * self.image_ubo_capacity + index) * self.image_ubo_stride;
    @memcpy(
        self.image_ubo.bytes.?[offset..][0..@sizeOf(kitty_image_mod.ImageConfig)],
        std.mem.asBytes(config),
    );
    gl.MemoryBarrier(gl.CLIENT_MAPPED_BUFFER_BARRIER_BIT);
    gl.BindBufferRange(
        gl.UNIFORM_BUFFER,
        0,
        self.image_ubo.name,
        @intCast(offset),
        @sizeOf(kitty_image_mod.ImageConfig),
    );
    gl.BindTextureUnit(5, texture);
    gl.DrawArrays(gl.TRIANGLE_STRIP, 0, 4);
}

fn ensureTabbarTexture(self: *Gl46Renderer, width: u32, height: u32) void {
    if (self.tabbar_texture != 0 and
        self.tabbar_size.cx == @as(i32, @intCast(width)) and
        self.tabbar_size.cy == @as(i32, @intCast(height))) return;
    if (self.tabbar_texture != 0) gl.DeleteTextures(1, @ptrCast(&self.tabbar_texture));
    self.tabbar_texture = createTexture(width, height, gl.RGBA8);
    self.tabbar_size = .{ .cx = @intCast(width), .cy = @intCast(height) };
}

pub fn applyGlyphResult(self: *Gl46Renderer, result: *RasterResult) bool {
    if (!self.initialized) return false;
    gl.makeProcTableCurrent(&self.procs);
    return glyph_mod.applyRasterResult(self, result);
}

pub fn reloadBackgroundImage(
    self: *Gl46Renderer,
    gpa: std.mem.Allocator,
    cfg: *const Config,
    hwnd: win32.HWND,
) void {
    self.ensureInitialized(hwnd);
    bg_image.reload(self, gpa, cfg, hwnd);
}

pub fn applyDecodedBackgroundImage(self: *Gl46Renderer, result: *const BgImageDecoded) void {
    if (!self.initialized) return;
    gl.makeProcTableCurrent(&self.procs);
    bg_image.applyDecoded(self, result);
}

pub fn releaseKittyImagesForTab(self: *Gl46Renderer, tab_id: types.TabId) void {
    if (self.initialized) gl.makeProcTableCurrent(&self.procs);
    self.kitty_images.releaseForTab(std.heap.page_allocator, tab_id);
}

test "OpenGL consumes the shared SPIR-V shader contract" {
    try std.testing.expectEqual(@as(u8, 4), gl.info.version_major);
    try std.testing.expectEqual(@as(u8, 6), gl.info.version_minor);
    try std.testing.expectEqual(shared.GlyphHandoff.cpu_pixels, glyph_handoff);
    inline for (.{ shader_assets.vertex, shader_assets.pixel, shader_assets.image_pixel }) |asset| {
        try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0x23, 0x07 }, asset.spirv[0..4]);
    }
}

test "three completion slots keep mapped frame data isolated" {
    try std.testing.expectEqual(@as(usize, 3), frame_count);
    var slot: usize = frame_count - 1;
    const expected = [_]usize{ 0, 1, 2, 0, 1, 2 };
    for (expected) |next| {
        slot = (slot + 1) % frame_count;
        try std.testing.expectEqual(next, slot);
    }
    try std.testing.expect(@sizeOf(shader.GridConfig) <= 256);
    try std.testing.expect(@sizeOf(kitty_image_mod.ImageConfig) <= 256);
}
