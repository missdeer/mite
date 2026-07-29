//! Presentation surface lifecycle for D3D12.
//!
//! Structurally the same assembly the other backend already uses: a
//! composition swap chain bound into a DirectComposition visual tree. That
//! reuse is deliberate — transparency, blur and the self-drawn window
//! decoration all come out of this path, and redesigning it for a second
//! backend would risk an appearance regression for no benefit. The only
//! difference is what the swap chain is created against: D3D12 presents from
//! a command queue rather than a device.
//!
//! The frame-latency waitable is handed out as a handle rather than wrapped in
//! a wait of its own: it is one of the two conditions the renderer's single
//! throttle decision solves together, and a wait primitive here would be a
//! second place to stall the frame path.

const std = @import("std");
const win32 = @import("win32").everything;

const pipeline = @import("pipeline.zig");

pub const Error = error{
    PresentationUnavailable,
};

/// DXGI success code for a fully covered window. Positive, so `hr < 0` will
/// not catch it.
pub const DXGI_STATUS_OCCLUDED: i32 = 0x087A0001;

pub const Surface = struct {
    swap_chain: *win32.IDXGISwapChain3,
    frame_latency_waitable: win32.HANDLE,
    dcomp_device: *win32.IDCompositionDevice,
    dcomp_target: *win32.IDCompositionTarget,
    dcomp_visual: *win32.IDCompositionVisual,

    pub fn init(
        queue: *win32.ID3D12CommandQueue,
        hwnd: win32.HWND,
        width: u32,
        height: u32,
    ) Error!Surface {
        var factory: *win32.IDXGIFactory4 = undefined;
        if (win32.CreateDXGIFactory1(win32.IID_IDXGIFactory4, @ptrCast(&factory)) < 0) {
            return error.PresentationUnavailable;
        }
        defer _ = factory.IUnknown.Release();

        const flags: u32 = @intFromEnum(win32.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT);
        var swap_chain1: *win32.IDXGISwapChain1 = undefined;
        {
            const desc = win32.DXGI_SWAP_CHAIN_DESC1{
                .Width = width,
                .Height = height,
                .Format = pipeline.render_target_format,
                .Stereo = 0,
                .SampleDesc = .{ .Count = 1, .Quality = 0 },
                .BufferUsage = win32.DXGI_USAGE_RENDER_TARGET_OUTPUT,
                // Three buffers give DWM a buffer of slack while its hold time
                // spikes during drag and resize; the frame-latency cap below
                // stops that turning into queued input latency.
                .BufferCount = 3,
                .Scaling = .STRETCH,
                .SwapEffect = .FLIP_SEQUENTIAL,
                .AlphaMode = .PREMULTIPLIED,
                .Flags = flags,
            };
            if (factory.IDXGIFactory2.CreateSwapChainForComposition(
                &queue.IUnknown,
                &desc,
                null,
                &swap_chain1,
            ) < 0) return error.PresentationUnavailable;
        }
        defer _ = swap_chain1.IUnknown.Release();

        var dcomp_device: *win32.IDCompositionDevice = undefined;
        if (win32.DCompositionCreateDevice(
            null,
            win32.IID_IDCompositionDevice,
            @ptrCast(&dcomp_device),
        ) < 0) return error.PresentationUnavailable;
        errdefer _ = dcomp_device.IUnknown.Release();

        var dcomp_target: *win32.IDCompositionTarget = undefined;
        if (dcomp_device.CreateTargetForHwnd(hwnd, 1, @ptrCast(&dcomp_target)) < 0) {
            return error.PresentationUnavailable;
        }
        errdefer _ = dcomp_target.IUnknown.Release();

        var dcomp_visual: *win32.IDCompositionVisual = undefined;
        if (dcomp_device.CreateVisual(@ptrCast(&dcomp_visual)) < 0) {
            return error.PresentationUnavailable;
        }
        errdefer _ = dcomp_visual.IUnknown.Release();

        if (dcomp_visual.SetContent(&swap_chain1.IUnknown) < 0) return error.PresentationUnavailable;
        if (dcomp_target.SetRoot(dcomp_visual) < 0) return error.PresentationUnavailable;
        if (dcomp_device.Commit() < 0) return error.PresentationUnavailable;

        var swap_chain3: *win32.IDXGISwapChain3 = undefined;
        if (swap_chain1.IUnknown.QueryInterface(
            win32.IID_IDXGISwapChain3,
            @ptrCast(&swap_chain3),
        ) < 0) return error.PresentationUnavailable;
        errdefer _ = swap_chain3.IUnknown.Release();

        if (swap_chain3.IDXGISwapChain2.SetMaximumFrameLatency(1) < 0) {
            return error.PresentationUnavailable;
        }
        const waitable = swap_chain3.IDXGISwapChain2.GetFrameLatencyWaitableObject() orelse
            return error.PresentationUnavailable;

        return .{
            .swap_chain = swap_chain3,
            .frame_latency_waitable = waitable,
            .dcomp_device = dcomp_device,
            .dcomp_target = dcomp_target,
            .dcomp_visual = dcomp_visual,
        };
    }

    pub fn deinit(self: *Surface) void {
        _ = win32.CloseHandle(self.frame_latency_waitable);
        _ = self.dcomp_visual.IUnknown.Release();
        _ = self.dcomp_target.IUnknown.Release();
        _ = self.dcomp_device.IUnknown.Release();
        _ = self.swap_chain.IUnknown.Release();
        self.* = undefined;
    }

    pub fn size(self: *Surface) ?struct { w: u32, h: u32 } {
        var w: u32 = undefined;
        var h: u32 = undefined;
        if (self.swap_chain.IDXGISwapChain2.GetSourceSize(&w, &h) < 0) return null;
        return .{ .w = w, .h = h };
    }

    pub fn resize(self: *Surface, width: u32, height: u32) Error!void {
        const flags: u32 = @intFromEnum(win32.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT);
        if (self.swap_chain.IDXGISwapChain.ResizeBuffers(0, width, height, .UNKNOWN, flags) < 0) {
            return error.PresentationUnavailable;
        }
    }

    pub fn currentBackBuffer(self: *Surface) ?*win32.ID3D12Resource {
        const index = self.swap_chain.GetCurrentBackBufferIndex();
        var buffer: *win32.ID3D12Resource = undefined;
        if (self.swap_chain.IDXGISwapChain.GetBuffer(
            index,
            win32.IID_ID3D12Resource,
            @ptrCast(&buffer),
        ) < 0) return null;
        return buffer;
    }
};

test "presentation reuses the same swap-chain format the grid renders into" {
    // The grid texture is copied wholesale into the back buffer, so the two
    // must stay in one format family; a mismatch turns the copy into a
    // reinterpretation and shifts every colour on screen.
    try std.testing.expectEqual(win32.DXGI_FORMAT.B8G8R8A8_UNORM, pipeline.render_target_format);
}
