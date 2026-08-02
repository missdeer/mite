//! Optional WGL/D3D11 bridge for DirectComposition presentation.
//!
//! The OpenGL renderer remains complete without this module. The bridge owns
//! only a multithread-capable D3D11 presentation device, the cross-API render
//! target, and the DirectComposition tree. Any capability or runtime failure
//! detaches that tree and leaves the caller on the baseline WGL path.

const std = @import("std");
const win32 = @import("win32").everything;
const shader_assets = @import("../shader_assets.zig");

const gl = @import("loader.zig");

const log = std.log.scoped(.gl46_interop);

const WGL_ACCESS_WRITE_DISCARD_NV: gl.@"enum" = 0x0002;
const DXGI_STATUS_OCCLUDED: i32 = 0x087A0001;
const interop_texture_format: win32.DXGI_FORMAT = .B8G8R8A8_UNORM;
const presentation_view_format: win32.DXGI_FORMAT = .B8G8R8A8_UNORM_SRGB;

fn interopDeviceFlags() win32.D3D11_CREATE_DEVICE_FLAG {
    // Omitting SINGLETHREADED is required by the D3D11 interop contract.
    return .{ .BGRA_SUPPORT = 1 };
}

pub const Path = enum {
    baseline,
    direct_composition,
};

pub const State = enum {
    untried,
    active,
    unavailable,
    failed,

    pub fn path(self: State) Path {
        return if (self == .active) .direct_composition else .baseline;
    }
};

const Error = error{
    ProceduresUnavailable,
    DeviceUnavailable,
    ShaderUnavailable,
    InteropDeviceUnavailable,
    FactoryUnavailable,
    SwapChainUnavailable,
    CompositionUnavailable,
    SurfaceUnavailable,
    RegistrationUnavailable,
    FramebufferIncomplete,
    SurfaceViewUnavailable,
    LockFailed,
    UnlockFailed,
    PresentFailed,
};

const WglDxOpenDevice = *const fn (*anyopaque) callconv(.winapi) ?win32.HANDLE;
const WglDxCloseDevice = *const fn (win32.HANDLE) callconv(.winapi) win32.BOOL;
const WglDxRegisterObject = *const fn (
    win32.HANDLE,
    *anyopaque,
    gl.uint,
    gl.@"enum",
    gl.@"enum",
) callconv(.winapi) ?win32.HANDLE;
const WglDxUnregisterObject = *const fn (
    win32.HANDLE,
    win32.HANDLE,
) callconv(.winapi) win32.BOOL;
const WglDxLockObjects = *const fn (
    win32.HANDLE,
    gl.int,
    [*]win32.HANDLE,
) callconv(.winapi) win32.BOOL;

const Procs = struct {
    open_device: WglDxOpenDevice,
    close_device: WglDxCloseDevice,
    register_object: WglDxRegisterObject,
    unregister_object: WglDxUnregisterObject,
    lock_objects: WglDxLockObjects,
    unlock_objects: WglDxLockObjects,

    fn load() ?Procs {
        return .{
            .open_device = procAddress(WglDxOpenDevice, "wglDXOpenDeviceNV") orelse return null,
            .close_device = procAddress(WglDxCloseDevice, "wglDXCloseDeviceNV") orelse return null,
            .register_object = procAddress(WglDxRegisterObject, "wglDXRegisterObjectNV") orelse return null,
            .unregister_object = procAddress(WglDxUnregisterObject, "wglDXUnregisterObjectNV") orelse return null,
            .lock_objects = procAddress(WglDxLockObjects, "wglDXLockObjectsNV") orelse return null,
            .unlock_objects = procAddress(WglDxLockObjects, "wglDXUnlockObjectsNV") orelse return null,
        };
    }
};

pub const Bridge = struct {
    procs: Procs,
    device: *win32.ID3D11Device,
    context: *win32.ID3D11DeviceContext,
    vertex_shader: *win32.ID3D11VertexShader,
    present_pixel_shader: *win32.ID3D11PixelShader,
    interop_device: win32.HANDLE,
    swap_chain: *win32.IDXGISwapChain2,
    frame_latency_waitable: win32.HANDLE,
    dcomp_device: *win32.IDCompositionDevice,
    dcomp_target: *win32.IDCompositionTarget,
    dcomp_visual: *win32.IDCompositionVisual,

    framebuffer: gl.uint,
    renderbuffer: gl.uint = 0,
    texture: ?*win32.ID3D11Texture2D = null,
    texture_view: ?*win32.ID3D11ShaderResourceView = null,
    interop_object: ?win32.HANDLE = null,
    width: u32 = 0,
    height: u32 = 0,
    locked: bool = false,
    active: bool = true,
    surface_verified: bool = false,

    pub fn init(hwnd: win32.HWND, width: u32, height: u32) Error!Bridge {
        const procs = Procs.load() orelse return error.ProceduresUnavailable;

        const levels = [_]win32.D3D_FEATURE_LEVEL{.@"11_0"};
        var device: *win32.ID3D11Device = undefined;
        var context: *win32.ID3D11DeviceContext = undefined;
        const create_hr = win32.D3D11CreateDevice(
            null,
            .HARDWARE,
            null,
            interopDeviceFlags(),
            &levels,
            levels.len,
            win32.D3D11_SDK_VERSION,
            &device,
            null,
            &context,
        );
        if (create_hr < 0) return error.DeviceUnavailable;
        errdefer {
            _ = context.IUnknown.Release();
            _ = device.IUnknown.Release();
        }

        var vertex_shader: *win32.ID3D11VertexShader = undefined;
        if (device.CreateVertexShader(
            shader_assets.vertex.dxbc.ptr,
            shader_assets.vertex.dxbc.len,
            null,
            &vertex_shader,
        ) < 0) return error.ShaderUnavailable;
        errdefer _ = vertex_shader.IUnknown.Release();

        var present_pixel_shader: *win32.ID3D11PixelShader = undefined;
        if (device.CreatePixelShader(
            shader_assets.present_pixel.ptr,
            shader_assets.present_pixel.len,
            null,
            &present_pixel_shader,
        ) < 0) return error.ShaderUnavailable;
        errdefer _ = present_pixel_shader.IUnknown.Release();

        const interop_device = procs.open_device(@ptrCast(device)) orelse
            return error.InteropDeviceUnavailable;
        errdefer _ = procs.close_device(interop_device);

        var dxgi_device: *win32.IDXGIDevice = undefined;
        if (device.IUnknown.QueryInterface(
            win32.IID_IDXGIDevice,
            @ptrCast(&dxgi_device),
        ) < 0) return error.FactoryUnavailable;
        defer _ = dxgi_device.IUnknown.Release();

        var adapter: *win32.IDXGIAdapter = undefined;
        if (dxgi_device.GetAdapter(&adapter) < 0) return error.FactoryUnavailable;
        defer _ = adapter.IUnknown.Release();

        var factory: *win32.IDXGIFactory2 = undefined;
        if (adapter.IDXGIObject.GetParent(
            win32.IID_IDXGIFactory2,
            @ptrCast(&factory),
        ) < 0) return error.FactoryUnavailable;
        defer _ = factory.IUnknown.Release();

        const flags: u32 = @intFromEnum(win32.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT);
        const desc = win32.DXGI_SWAP_CHAIN_DESC1{
            .Width = width,
            .Height = height,
            .Format = .B8G8R8A8_UNORM,
            .Stereo = 0,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .BufferUsage = win32.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 3,
            .Scaling = .STRETCH,
            .SwapEffect = .FLIP_SEQUENTIAL,
            .AlphaMode = .PREMULTIPLIED,
            .Flags = flags,
        };
        var swap_chain1: *win32.IDXGISwapChain1 = undefined;
        if (factory.CreateSwapChainForComposition(
            &device.IUnknown,
            &desc,
            null,
            &swap_chain1,
        ) < 0) return error.SwapChainUnavailable;
        defer _ = swap_chain1.IUnknown.Release();

        var swap_chain: *win32.IDXGISwapChain2 = undefined;
        if (swap_chain1.IUnknown.QueryInterface(
            win32.IID_IDXGISwapChain2,
            @ptrCast(&swap_chain),
        ) < 0) return error.SwapChainUnavailable;
        errdefer _ = swap_chain.IUnknown.Release();
        if (swap_chain.SetMaximumFrameLatency(1) < 0) return error.SwapChainUnavailable;
        const waitable = swap_chain.GetFrameLatencyWaitableObject() orelse
            return error.SwapChainUnavailable;
        errdefer _ = win32.CloseHandle(waitable);

        var dcomp_device: *win32.IDCompositionDevice = undefined;
        if (win32.DCompositionCreateDevice(
            dxgi_device,
            win32.IID_IDCompositionDevice,
            @ptrCast(&dcomp_device),
        ) < 0) return error.CompositionUnavailable;
        errdefer _ = dcomp_device.IUnknown.Release();

        var dcomp_target: *win32.IDCompositionTarget = undefined;
        if (dcomp_device.CreateTargetForHwnd(hwnd, 1, @ptrCast(&dcomp_target)) < 0) {
            return error.CompositionUnavailable;
        }
        errdefer _ = dcomp_target.IUnknown.Release();

        var dcomp_visual: *win32.IDCompositionVisual = undefined;
        if (dcomp_device.CreateVisual(@ptrCast(&dcomp_visual)) < 0) {
            return error.CompositionUnavailable;
        }
        errdefer _ = dcomp_visual.IUnknown.Release();
        if (dcomp_visual.SetContent(&swap_chain1.IUnknown) < 0 or
            dcomp_target.SetRoot(dcomp_visual) < 0 or
            dcomp_device.Commit() < 0)
        {
            return error.CompositionUnavailable;
        }

        var framebuffer: gl.uint = 0;
        gl.CreateFramebuffers(1, @ptrCast(&framebuffer));
        if (framebuffer == 0) return error.SurfaceUnavailable;

        var bridge: Bridge = .{
            .procs = procs,
            .device = device,
            .context = context,
            .vertex_shader = vertex_shader,
            .present_pixel_shader = present_pixel_shader,
            .interop_device = interop_device,
            .swap_chain = swap_chain,
            .frame_latency_waitable = waitable,
            .dcomp_device = dcomp_device,
            .dcomp_target = dcomp_target,
            .dcomp_visual = dcomp_visual,
            .framebuffer = framebuffer,
        };
        bridge.recreateSurface(width, height) catch |err| {
            gl.DeleteFramebuffers(1, @ptrCast(&framebuffer));
            return err;
        };
        return bridge;
    }

    pub fn deinit(self: *Bridge) void {
        self.disable();
        if (self.locked) {
            log.err("leaving a failed locked interop object to process teardown", .{});
            return;
        }
        self.releaseSurface();
        if (self.framebuffer != 0) gl.DeleteFramebuffers(1, @ptrCast(&self.framebuffer));
        _ = self.procs.close_device(self.interop_device);
        _ = win32.CloseHandle(self.frame_latency_waitable);
        _ = self.dcomp_visual.IUnknown.Release();
        _ = self.dcomp_target.IUnknown.Release();
        _ = self.dcomp_device.IUnknown.Release();
        _ = self.swap_chain.IUnknown.Release();
        _ = self.present_pixel_shader.IUnknown.Release();
        _ = self.vertex_shader.IUnknown.Release();
        self.context.ClearState();
        self.context.Flush();
        _ = self.context.IUnknown.Release();
        _ = self.device.IUnknown.Release();
        self.* = undefined;
    }

    pub fn begin(self: *Bridge, width: u32, height: u32) Error!void {
        if (!self.active) return error.LockFailed;
        if (self.width != width or self.height != height) {
            try self.recreateSurface(width, height);
        }
        _ = win32.WaitForSingleObjectEx(self.frame_latency_waitable, 100, 0);
        try self.lock();
        gl.BindFramebuffer(gl.FRAMEBUFFER, self.framebuffer);
        if (!self.surface_verified) {
            if (gl.CheckNamedFramebufferStatus(self.framebuffer, gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE) {
                gl.BindFramebuffer(gl.FRAMEBUFFER, 0);
                return error.FramebufferIncomplete;
            }
            self.surface_verified = true;
        }
    }

    pub fn present(self: *Bridge) Error!void {
        gl.Flush();
        try self.unlock();
        gl.BindFramebuffer(gl.FRAMEBUFFER, 0);

        var back_buffer: *win32.ID3D11Texture2D = undefined;
        if (self.swap_chain.IDXGISwapChain.GetBuffer(
            0,
            win32.IID_ID3D11Texture2D,
            @ptrCast(&back_buffer),
        ) < 0) return error.PresentFailed;
        defer _ = back_buffer.IUnknown.Release();

        const rtv_desc: win32.D3D11_RENDER_TARGET_VIEW_DESC = .{
            .Format = presentation_view_format,
            .ViewDimension = .TEXTURE2D,
            .Anonymous = .{ .Texture2D = .{ .MipSlice = 0 } },
        };
        var render_target: *win32.ID3D11RenderTargetView = undefined;
        if (self.device.CreateRenderTargetView(
            &back_buffer.ID3D11Resource,
            &rtv_desc,
            &render_target,
        ) < 0) return error.PresentFailed;
        defer _ = render_target.IUnknown.Release();

        var targets = [_]?*win32.ID3D11RenderTargetView{render_target};
        self.context.OMSetRenderTargets(targets.len, &targets, null);
        var viewport: win32.D3D11_VIEWPORT = .{
            .TopLeftX = 0,
            .TopLeftY = 0,
            .Width = @floatFromInt(self.width),
            .Height = @floatFromInt(self.height),
            .MinDepth = 0,
            .MaxDepth = 0,
        };
        self.context.RSSetViewports(1, @ptrCast(&viewport));
        self.context.IASetPrimitiveTopology(._PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
        self.context.VSSetShader(self.vertex_shader, null, 0);
        self.context.PSSetShader(self.present_pixel_shader, null, 0);
        var resources = [_]?*win32.ID3D11ShaderResourceView{self.texture_view.?};
        self.context.PSSetShaderResources(4, resources.len, &resources);
        self.context.Draw(4, 0);
        var no_resources = [_]?*win32.ID3D11ShaderResourceView{null};
        self.context.PSSetShaderResources(4, no_resources.len, &no_resources);
        self.context.OMSetRenderTargets(0, null, null);

        const hr = self.swap_chain.IDXGISwapChain.Present(0, 0);
        if (hr < 0 and hr != DXGI_STATUS_OCCLUDED) return error.PresentFailed;
    }

    pub fn disable(self: *Bridge) void {
        if (!self.active and !self.locked) return;
        gl.BindFramebuffer(gl.FRAMEBUFFER, 0);
        if (self.active) {
            _ = self.dcomp_target.SetRoot(null);
            _ = self.dcomp_device.Commit();
        }
        self.active = false;
        if (self.locked) {
            gl.Finish();
            self.unlock() catch return;
        }
    }

    fn recreateSurface(self: *Bridge, width: u32, height: u32) Error!void {
        const had_surface = self.width != 0 or self.height != 0;
        self.releaseSurface();
        if (had_surface) {
            self.context.ClearState();
            self.context.Flush();
            const flags: u32 = @intFromEnum(win32.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT);
            if (self.swap_chain.IDXGISwapChain.ResizeBuffers(
                0,
                width,
                height,
                .UNKNOWN,
                flags,
            ) < 0) return error.SurfaceUnavailable;
        }

        const desc: win32.D3D11_TEXTURE2D_DESC = .{
            .Width = width,
            .Height = height,
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = interop_texture_format,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Usage = .DEFAULT,
            .BindFlags = .{ .SHADER_RESOURCE = 1, .RENDER_TARGET = 1 },
            .CPUAccessFlags = .{},
            .MiscFlags = .{},
        };
        var texture: *win32.ID3D11Texture2D = undefined;
        if (self.device.CreateTexture2D(&desc, null, &texture) < 0) {
            return error.SurfaceUnavailable;
        }
        errdefer _ = texture.IUnknown.Release();

        var texture_view: *win32.ID3D11ShaderResourceView = undefined;
        if (self.device.CreateShaderResourceView(
            &texture.ID3D11Resource,
            null,
            &texture_view,
        ) < 0) return error.SurfaceViewUnavailable;
        errdefer _ = texture_view.IUnknown.Release();

        var renderbuffer: gl.uint = 0;
        gl.GenRenderbuffers(1, @ptrCast(&renderbuffer));
        if (renderbuffer == 0) return error.SurfaceUnavailable;
        errdefer gl.DeleteRenderbuffers(1, @ptrCast(&renderbuffer));

        const object = self.procs.register_object(
            self.interop_device,
            @ptrCast(texture),
            renderbuffer,
            gl.RENDERBUFFER,
            WGL_ACCESS_WRITE_DISCARD_NV,
        ) orelse return error.RegistrationUnavailable;
        errdefer _ = self.procs.unregister_object(self.interop_device, object);

        // The NV specification's D3D11 sample attaches registered objects
        // while unlocked; the per-frame lock gates access to their storage.
        gl.NamedFramebufferRenderbuffer(
            self.framebuffer,
            gl.COLOR_ATTACHMENT0,
            gl.RENDERBUFFER,
            renderbuffer,
        );
        errdefer gl.NamedFramebufferRenderbuffer(
            self.framebuffer,
            gl.COLOR_ATTACHMENT0,
            gl.RENDERBUFFER,
            0,
        );
        gl.NamedFramebufferDrawBuffer(self.framebuffer, gl.COLOR_ATTACHMENT0);

        self.texture = texture;
        self.texture_view = texture_view;
        self.renderbuffer = renderbuffer;
        self.interop_object = object;
        self.width = width;
        self.height = height;
        self.surface_verified = false;
    }

    fn releaseSurface(self: *Bridge) void {
        if (self.locked) return;
        if (self.interop_object) |object| {
            gl.NamedFramebufferRenderbuffer(
                self.framebuffer,
                gl.COLOR_ATTACHMENT0,
                gl.RENDERBUFFER,
                0,
            );
            if (self.procs.unregister_object(self.interop_device, object) == 0) {
                log.warn("wglDXUnregisterObjectNV failed during surface release", .{});
            }
            self.interop_object = null;
        }
        if (self.renderbuffer != 0) {
            gl.DeleteRenderbuffers(1, @ptrCast(&self.renderbuffer));
            self.renderbuffer = 0;
        }
        if (self.texture_view) |texture_view| {
            _ = texture_view.IUnknown.Release();
            self.texture_view = null;
        }
        if (self.texture) |texture| {
            _ = texture.IUnknown.Release();
            self.texture = null;
        }
        self.width = 0;
        self.height = 0;
        self.surface_verified = false;
    }

    fn lock(self: *Bridge) Error!void {
        var objects = [_]win32.HANDLE{self.interop_object.?};
        if (self.procs.lock_objects(self.interop_device, 1, &objects) == 0) {
            return error.LockFailed;
        }
        self.locked = true;
    }

    fn unlock(self: *Bridge) Error!void {
        var objects = [_]win32.HANDLE{self.interop_object.?};
        if (self.procs.unlock_objects(self.interop_device, 1, &objects) == 0) {
            return error.UnlockFailed;
        }
        self.locked = false;
    }
};

fn procAddress(comptime T: type, name: [*:0]const u8) ?T {
    const candidate = win32.wglGetProcAddress(name) orelse return null;
    const raw = @intFromPtr(candidate);
    if (raw <= 3 or raw == std.math.maxInt(usize)) return null;
    return @ptrCast(candidate);
}

test "only an active bridge replaces the usable baseline presentation" {
    try std.testing.expectEqual(Path.baseline, State.untried.path());
    try std.testing.expectEqual(Path.baseline, State.unavailable.path());
    try std.testing.expectEqual(Path.baseline, State.failed.path());
    try std.testing.expectEqual(Path.direct_composition, State.active.path());
}

test "interop device creation remains multithread capable" {
    const flags = interopDeviceFlags();
    try std.testing.expectEqual(@as(u1, 0), flags.SINGLETHREADED);
    try std.testing.expectEqual(@as(u1, 1), flags.BGRA_SUPPORT);
}

test "interop presentation encodes linear shader output as sRGB" {
    try std.testing.expectEqual(
        win32.DXGI_FORMAT.B8G8R8A8_UNORM,
        interop_texture_format,
    );
    try std.testing.expectEqual(
        win32.DXGI_FORMAT.B8G8R8A8_UNORM_SRGB,
        presentation_view_format,
    );
}
