//! D3D12 device, queue and explicit-synchronization skeleton.
//!
//! Deliberately absent from `Renderer.RendererBackend`: the facade contract is
//! all-or-nothing, and this module cannot honour it yet. It exists so the two
//! risks that would sink a D3D12 backend — shader assets the runtime refuses,
//! and an explicit synchronization model that cannot be stood up here — are
//! settled before any drawing work is built on top of them.

const std = @import("std");
const win32 = @import("win32").everything;

const shader_assets = @import("shader_assets.zig");

pub const Error = error{
    AdapterUnavailable,
    DeviceUnavailable,
    SyncSkeletonFailed,
    ShaderAssetRejected,
};

/// Matches the swap chain format D3D11 already presents with, so the pipeline
/// validated here is validated against the format the real backend will use.
const render_target_format: win32.DXGI_FORMAT = .B8G8R8A8_UNORM;

pub const Skeleton = struct {
    device: *win32.ID3D12Device,
    queue: *win32.ID3D12CommandQueue,
    command_allocator: *win32.ID3D12CommandAllocator,
    command_list: *win32.ID3D12GraphicsCommandList,
    fence: *win32.ID3D12Fence,
    fence_event: win32.HANDLE,
    fence_value: u64,

    /// WARP rather than the installed GPU: this skeleton proves the API
    /// contract holds, and a software adapter keeps that answer independent of
    /// whichever card the machine happens to have.
    pub fn initWarp() Error!Skeleton {
        var factory: *win32.IDXGIFactory4 = undefined;
        if (win32.CreateDXGIFactory1(win32.IID_IDXGIFactory4, @ptrCast(&factory)) < 0) {
            return error.AdapterUnavailable;
        }
        defer _ = factory.IUnknown.Release();

        var adapter: *win32.IDXGIAdapter = undefined;
        if (factory.EnumWarpAdapter(win32.IID_IDXGIAdapter, @ptrCast(&adapter)) < 0) {
            return error.AdapterUnavailable;
        }
        defer _ = adapter.IUnknown.Release();

        var device: *win32.ID3D12Device = undefined;
        if (win32.D3D12CreateDevice(
            @ptrCast(adapter),
            .@"11_0",
            win32.IID_ID3D12Device,
            @ptrCast(&device),
        ) < 0) {
            return error.DeviceUnavailable;
        }
        errdefer _ = device.IUnknown.Release();

        const queue_desc = win32.D3D12_COMMAND_QUEUE_DESC{
            .Type = .DIRECT,
            .Priority = 0,
            .Flags = .{},
            .NodeMask = 0,
        };
        var queue: *win32.ID3D12CommandQueue = undefined;
        if (device.CreateCommandQueue(&queue_desc, win32.IID_ID3D12CommandQueue, @ptrCast(&queue)) < 0) {
            return error.SyncSkeletonFailed;
        }
        errdefer _ = queue.IUnknown.Release();

        var command_allocator: *win32.ID3D12CommandAllocator = undefined;
        if (device.CreateCommandAllocator(
            .DIRECT,
            win32.IID_ID3D12CommandAllocator,
            @ptrCast(&command_allocator),
        ) < 0) {
            return error.SyncSkeletonFailed;
        }
        errdefer _ = command_allocator.IUnknown.Release();

        var command_list: *win32.ID3D12GraphicsCommandList = undefined;
        if (device.CreateCommandList(
            0,
            .DIRECT,
            command_allocator,
            null,
            win32.IID_ID3D12GraphicsCommandList,
            @ptrCast(&command_list),
        ) < 0) {
            return error.SyncSkeletonFailed;
        }
        errdefer _ = command_list.IUnknown.Release();

        var fence: *win32.ID3D12Fence = undefined;
        if (device.CreateFence(0, .{}, win32.IID_ID3D12Fence, @ptrCast(&fence)) < 0) {
            return error.SyncSkeletonFailed;
        }
        errdefer _ = fence.IUnknown.Release();

        const fence_event = win32.CreateEventW(null, 0, 0, null) orelse return error.SyncSkeletonFailed;

        return .{
            .device = device,
            .queue = queue,
            .command_allocator = command_allocator,
            .command_list = command_list,
            .fence = fence,
            .fence_event = fence_event,
            .fence_value = 0,
        };
    }

    pub fn deinit(self: *Skeleton) void {
        _ = win32.CloseHandle(self.fence_event);
        _ = self.fence.IUnknown.Release();
        _ = self.command_list.IUnknown.Release();
        _ = self.command_allocator.IUnknown.Release();
        _ = self.queue.IUnknown.Release();
        _ = self.device.IUnknown.Release();
        self.* = undefined;
    }

    /// One full explicit-synchronization cycle: record, submit, signal, wait.
    /// This is the whole behavioural difference from D3D11, where the driver
    /// does all of it implicitly, so it is worth standing up on its own.
    pub fn submitAndWait(self: *Skeleton) Error!void {
        if (self.command_list.Close() < 0) return error.SyncSkeletonFailed;
        // A failure after Close() would otherwise strand the list closed, so
        // every later call would fail at Close() instead of at the real cause.
        errdefer _ = self.command_list.Reset(self.command_allocator, null);

        var lists = [_]?*win32.ID3D12CommandList{@ptrCast(self.command_list)};
        self.queue.ExecuteCommandLists(lists.len, &lists);

        self.fence_value += 1;
        if (self.queue.Signal(self.fence, self.fence_value) < 0) return error.SyncSkeletonFailed;

        if (self.fence.GetCompletedValue() < self.fence_value) {
            if (self.fence.SetEventOnCompletion(self.fence_value, self.fence_event) < 0) {
                return error.SyncSkeletonFailed;
            }
            // WAIT_OBJECT_0 is zero, which this enum spells NO_ERROR.
            if (win32.WaitForSingleObject(self.fence_event, 10_000) != .NO_ERROR) {
                return error.SyncSkeletonFailed;
            }
        }
        if (self.fence.GetCompletedValue() < self.fence_value) return error.SyncSkeletonFailed;

        if (self.command_allocator.Reset() < 0) return error.SyncSkeletonFailed;
        if (self.command_list.Reset(self.command_allocator, null) < 0) return error.SyncSkeletonFailed;
    }

    /// Proves the runtime accepts the generated DXIL. Building the assets says
    /// nothing about this: a wrong shader model, an unsupported feature or a
    /// missing signature only surfaces when D3D12 is asked to consume them.
    pub fn verifyShaderAssetsAccepted(self: *Skeleton) Error!void {
        const root_signature = try self.createVerificationRootSignature();
        defer _ = root_signature.IUnknown.Release();

        inline for (.{ shader_assets.pixel, shader_assets.image_pixel }) |pixel_targets| {
            const pipeline = try self.createVerificationPipeline(root_signature, pixel_targets.dxil);
            _ = pipeline.IUnknown.Release();
        }
    }

    /// Covers every register the shaders declare (b0, t0..t3, s0) and nothing
    /// else. This is a verification artifact, not the binding layout the real
    /// backend will want — that one has to serve drawing, and belongs with the
    /// slice that does the drawing.
    fn createVerificationRootSignature(self: *Skeleton) Error!*win32.ID3D12RootSignature {
        const srv_range = win32.D3D12_DESCRIPTOR_RANGE{
            .RangeType = .SRV,
            .NumDescriptors = 4,
            .BaseShaderRegister = 0,
            .RegisterSpace = 0,
            .OffsetInDescriptorsFromTableStart = 0,
        };
        const parameters = [_]win32.D3D12_ROOT_PARAMETER{
            .{
                .ParameterType = .CBV,
                .Anonymous = .{ .Descriptor = .{ .ShaderRegister = 0, .RegisterSpace = 0 } },
                .ShaderVisibility = .ALL,
            },
            .{
                .ParameterType = .DESCRIPTOR_TABLE,
                .Anonymous = .{ .DescriptorTable = .{
                    .NumDescriptorRanges = 1,
                    .pDescriptorRanges = &srv_range,
                } },
                .ShaderVisibility = .PIXEL,
            },
        };
        const samplers = [_]win32.D3D12_STATIC_SAMPLER_DESC{.{
            .Filter = .MIN_MAG_MIP_LINEAR,
            .AddressU = .CLAMP,
            .AddressV = .CLAMP,
            .AddressW = .CLAMP,
            .MipLODBias = 0,
            .MaxAnisotropy = 0,
            .ComparisonFunc = .NEVER,
            .BorderColor = .TRANSPARENT_BLACK,
            .MinLOD = 0,
            .MaxLOD = 0,
            .ShaderRegister = 0,
            .RegisterSpace = 0,
            .ShaderVisibility = .PIXEL,
        }};
        const desc = win32.D3D12_ROOT_SIGNATURE_DESC{
            .NumParameters = parameters.len,
            .pParameters = &parameters[0],
            .NumStaticSamplers = samplers.len,
            .pStaticSamplers = &samplers[0],
            .Flags = .{ .ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT = 1 },
        };

        var blob: ?*win32.ID3DBlob = null;
        var error_blob: ?*win32.ID3DBlob = null;
        const serialize_hr = win32.D3D12SerializeRootSignature(&desc, .@"1", &blob, &error_blob);
        // Both out-parameters can be populated independently of the result, so
        // release whatever came back on every path.
        defer if (error_blob) |b| {
            _ = b.IUnknown.Release();
        };
        defer if (blob) |b| {
            _ = b.IUnknown.Release();
        };
        if (serialize_hr < 0) return error.ShaderAssetRejected;
        const serialized = blob orelse return error.ShaderAssetRejected;

        var root_signature: *win32.ID3D12RootSignature = undefined;
        if (self.device.CreateRootSignature(
            0,
            @ptrCast(serialized.GetBufferPointer()),
            serialized.GetBufferSize(),
            win32.IID_ID3D12RootSignature,
            @ptrCast(&root_signature),
        ) < 0) {
            return error.ShaderAssetRejected;
        }
        return root_signature;
    }

    fn createVerificationPipeline(
        self: *Skeleton,
        root_signature: *win32.ID3D12RootSignature,
        pixel_dxil: []const u8,
    ) Error!*win32.ID3D12PipelineState {
        var desc = std.mem.zeroes(win32.D3D12_GRAPHICS_PIPELINE_STATE_DESC);
        desc.pRootSignature = root_signature;
        desc.VS = .{
            .pShaderBytecode = shader_assets.vertex.dxil.ptr,
            .BytecodeLength = shader_assets.vertex.dxil.len,
        };
        desc.PS = .{ .pShaderBytecode = pixel_dxil.ptr, .BytecodeLength = pixel_dxil.len };
        desc.SampleMask = std.math.maxInt(u32);
        desc.RasterizerState = .{
            .FillMode = .SOLID,
            .CullMode = .NONE,
            .FrontCounterClockwise = win32.FALSE,
            .DepthBias = 0,
            .DepthBiasClamp = 0,
            .SlopeScaledDepthBias = 0,
            .DepthClipEnable = win32.TRUE,
            .MultisampleEnable = win32.FALSE,
            .AntialiasedLineEnable = win32.FALSE,
            .ForcedSampleCount = 0,
            .ConservativeRaster = .FF,
        };
        desc.BlendState.RenderTarget[0].RenderTargetWriteMask = 0xF;
        desc.PrimitiveTopologyType = .TRIANGLE;
        desc.NumRenderTargets = 1;
        desc.RTVFormats[0] = render_target_format;
        desc.SampleDesc = .{ .Count = 1, .Quality = 0 };

        var pipeline: *win32.ID3D12PipelineState = undefined;
        if (self.device.CreateGraphicsPipelineState(
            &desc,
            win32.IID_ID3D12PipelineState,
            @ptrCast(&pipeline),
        ) < 0) {
            return error.ShaderAssetRejected;
        }
        return pipeline;
    }
};

test "D3D12 completes an explicit record, submit, signal and wait cycle" {
    var skeleton = try Skeleton.initWarp();
    defer skeleton.deinit();

    try std.testing.expectEqual(@as(u64, 0), skeleton.fence.GetCompletedValue());
    try skeleton.submitAndWait();
    try std.testing.expectEqual(@as(u64, 1), skeleton.fence.GetCompletedValue());

    // A second cycle proves the fence and allocator are reusable rather than
    // one-shot, which is what the sustained-frame slice will depend on.
    try skeleton.submitAndWait();
    try std.testing.expectEqual(@as(u64, 2), skeleton.fence.GetCompletedValue());
}

test "D3D12 accepts every generated Shader Model 6 asset" {
    var skeleton = try Skeleton.initWarp();
    defer skeleton.deinit();

    try skeleton.verifyShaderAssetsAccepted();
}

test "D3D12 rejects the Shader Model 5 assets D3D11 consumes" {
    // Guards the reason this slice exists: the two DirectX targets are not
    // interchangeable, so a build that quietly fed D3D12 the D3D11 asset must
    // not look like success.
    var skeleton = try Skeleton.initWarp();
    defer skeleton.deinit();

    const root_signature = try skeleton.createVerificationRootSignature();
    defer _ = root_signature.IUnknown.Release();

    try std.testing.expectError(
        error.ShaderAssetRejected,
        skeleton.createVerificationPipeline(root_signature, shader_assets.pixel.dxbc),
    );
}
