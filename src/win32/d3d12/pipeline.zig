//! Resource binding layout, pipeline state and descriptor organization.
//!
//! The shader source is shared with every other backend, so the binding
//! layout here is not free to cover only what text needs: it must declare
//! every resource the shader declares (b0, t0..t3, s0). Covering a subset
//! would mean either forking the shader — losing the single-source property
//! this whole effort rests on — or presenting a degraded picture, and a
//! backend that can only present a degraded picture is not allowed to be
//! selectable at all.

const std = @import("std");
const win32 = @import("win32").everything;

const shader_assets = @import("../shader_assets.zig");

pub const Error = error{
    BindingLayoutRejected,
    PipelineRejected,
    DescriptorHeapUnavailable,
};

/// Descriptors the shader reads, in register order: cells, glyph atlas,
/// background image, inline image.
pub const srv_count: u32 = 4;

/// Inline images are drawn one placement at a time, and the GPU reads
/// descriptors when the work executes rather than when it is recorded — so
/// every placement in a frame needs its own table rather than one table
/// rewritten in place. Table 0 is the grid pass; the rest are placements.
///
/// The heap grows to whatever a frame actually needs; this is only the size
/// it starts at, chosen to cover ordinary use without reallocating.
pub const initial_table_count: u32 = 1 + 64;

pub const render_target_format: win32.DXGI_FORMAT = .B8G8R8A8_UNORM;
/// Drawing goes through an sRGB view so the GPU encodes on store, matching
/// how the other backend produces the bytes it presents. Getting this wrong
/// shows up as a whole-screen gamma shift, which is exactly the class of
/// difference that counts as a regression rather than a backend variation.
pub const render_target_view_format: win32.DXGI_FORMAT = .B8G8R8A8_UNORM_SRGB;
pub const grid_resource_format: win32.DXGI_FORMAT = .B8G8R8A8_TYPELESS;

/// b0 as a root descriptor, t0..t3 as one table, s0 static.
///
/// The constant buffer is a root descriptor rather than a table entry because
/// it changes for every draw in the inline-image pass; keeping it out of the
/// table means those draws only vary one root argument.
pub fn createRootSignature(device: *win32.ID3D12Device) Error!*win32.ID3D12RootSignature {
    const srv_range = win32.D3D12_DESCRIPTOR_RANGE{
        .RangeType = .SRV,
        .NumDescriptors = srv_count,
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
    const hr = win32.D3D12SerializeRootSignature(&desc, .@"1", &blob, &error_blob);
    defer if (error_blob) |b| {
        _ = b.IUnknown.Release();
    };
    defer if (blob) |b| {
        _ = b.IUnknown.Release();
    };
    if (hr < 0) return error.BindingLayoutRejected;
    const serialized = blob orelse return error.BindingLayoutRejected;

    var root_signature: *win32.ID3D12RootSignature = undefined;
    if (device.CreateRootSignature(
        0,
        @ptrCast(serialized.GetBufferPointer()),
        serialized.GetBufferSize(),
        win32.IID_ID3D12RootSignature,
        @ptrCast(&root_signature),
    ) < 0) return error.BindingLayoutRejected;
    return root_signature;
}

pub const Blend = enum {
    /// The grid pass writes every pixel it covers, including the background
    /// of blank cells, so there is nothing underneath to blend with.
    opaque_write,
    /// Inline images composite over already-drawn text.
    premultiplied_over,
};

pub fn createPipeline(
    device: *win32.ID3D12Device,
    root_signature: *win32.ID3D12RootSignature,
    pixel_dxil: []const u8,
    blend: Blend,
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
    desc.BlendState.RenderTarget[0] = switch (blend) {
        .opaque_write => .{
            .BlendEnable = win32.FALSE,
            .LogicOpEnable = win32.FALSE,
            .SrcBlend = .ONE,
            .DestBlend = .ZERO,
            .BlendOp = .ADD,
            .SrcBlendAlpha = .ONE,
            .DestBlendAlpha = .ZERO,
            .BlendOpAlpha = .ADD,
            .LogicOp = .NOOP,
            .RenderTargetWriteMask = 0xF,
        },
        .premultiplied_over => .{
            .BlendEnable = win32.TRUE,
            .LogicOpEnable = win32.FALSE,
            .SrcBlend = .ONE,
            .DestBlend = .INV_SRC_ALPHA,
            .BlendOp = .ADD,
            .SrcBlendAlpha = .ONE,
            .DestBlendAlpha = .INV_SRC_ALPHA,
            .BlendOpAlpha = .ADD,
            .LogicOp = .NOOP,
            .RenderTargetWriteMask = 0xF,
        },
    };
    desc.PrimitiveTopologyType = .TRIANGLE;
    desc.NumRenderTargets = 1;
    desc.RTVFormats[0] = render_target_view_format;
    desc.SampleDesc = .{ .Count = 1, .Quality = 0 };

    var pipeline: *win32.ID3D12PipelineState = undefined;
    if (device.CreateGraphicsPipelineState(
        &desc,
        win32.IID_ID3D12PipelineState,
        @ptrCast(&pipeline),
    ) < 0) return error.PipelineRejected;
    return pipeline;
}

/// Shader-visible descriptor storage, addressed as `table_count` groups of
/// `srv_count`.
pub const Descriptors = struct {
    heap: *win32.ID3D12DescriptorHeap,
    increment: u32,
    table_count: u32,
    cpu_start: win32.D3D12_CPU_DESCRIPTOR_HANDLE,
    gpu_start: win32.D3D12_GPU_DESCRIPTOR_HANDLE,

    pub fn init(device: *win32.ID3D12Device, tables: u32) Error!Descriptors {
        const table_count = @max(tables, initial_table_count);
        const desc = win32.D3D12_DESCRIPTOR_HEAP_DESC{
            .Type = .CBV_SRV_UAV,
            .NumDescriptors = srv_count * table_count,
            .Flags = .{ .SHADER_VISIBLE = 1 },
            .NodeMask = 0,
        };
        var heap: *win32.ID3D12DescriptorHeap = undefined;
        if (device.CreateDescriptorHeap(&desc, win32.IID_ID3D12DescriptorHeap, @ptrCast(&heap)) < 0) {
            return error.DescriptorHeapUnavailable;
        }
        return .{
            .heap = heap,
            .increment = device.GetDescriptorHandleIncrementSize(.CBV_SRV_UAV),
            .table_count = table_count,
            .cpu_start = heap.GetCPUDescriptorHandleForHeapStart(),
            .gpu_start = heap.GetGPUDescriptorHandleForHeapStart(),
        };
    }

    pub fn release(self: *Descriptors) void {
        _ = self.heap.IUnknown.Release();
    }

    pub fn cpu(self: Descriptors, table: u32, slot: u32) win32.D3D12_CPU_DESCRIPTOR_HANDLE {
        return .{ .ptr = self.cpu_start.ptr + (table * srv_count + slot) * self.increment };
    }

    pub fn gpu(self: Descriptors, table: u32) win32.D3D12_GPU_DESCRIPTOR_HANDLE {
        return .{ .ptr = self.gpu_start.ptr + @as(u64, table * srv_count) * self.increment };
    }
};

/// Render-target descriptors, which are never shader-visible.
pub const RenderTargets = struct {
    heap: *win32.ID3D12DescriptorHeap,

    pub fn init(device: *win32.ID3D12Device) Error!RenderTargets {
        const desc = win32.D3D12_DESCRIPTOR_HEAP_DESC{
            .Type = .RTV,
            .NumDescriptors = 1,
            .Flags = .{},
            .NodeMask = 0,
        };
        var heap: *win32.ID3D12DescriptorHeap = undefined;
        if (device.CreateDescriptorHeap(&desc, win32.IID_ID3D12DescriptorHeap, @ptrCast(&heap)) < 0) {
            return error.DescriptorHeapUnavailable;
        }
        return .{ .heap = heap };
    }

    pub fn release(self: *RenderTargets) void {
        _ = self.heap.IUnknown.Release();
    }

    pub fn cpu(self: RenderTargets) win32.D3D12_CPU_DESCRIPTOR_HANDLE {
        return self.heap.GetCPUDescriptorHandleForHeapStart();
    }
};

test "the descriptor heap always has room for the grid pass plus inline images" {
    // One table rewritten between draws would be read after the fact by the
    // GPU and every placement would sample the last image, so a table per
    // placement is a correctness requirement rather than a convenience.
    try std.testing.expect(initial_table_count > 1);
}

test "descriptor tables do not overlap" {
    const d: Descriptors = .{
        .heap = @ptrFromInt(0x1000),
        .increment = 32,
        .table_count = initial_table_count,
        .cpu_start = .{ .ptr = 0 },
        .gpu_start = .{ .ptr = 0 },
    };
    // Last slot of table 0 must sit strictly before the first slot of table 1.
    try std.testing.expectEqual(@as(usize, 3 * 32), d.cpu(0, 3).ptr);
    try std.testing.expectEqual(@as(usize, 4 * 32), d.cpu(1, 0).ptr);
    try std.testing.expectEqual(@as(u64, 4 * 32), d.gpu(1).ptr);
}

test "the grid render target is viewed as sRGB over a typeless resource" {
    // A UNORM resource refuses an sRGB view, and presenting without the sRGB
    // encode shifts the whole picture's gamma — a regression, not a
    // permissible backend difference.
    try std.testing.expectEqual(win32.DXGI_FORMAT.B8G8R8A8_TYPELESS, grid_resource_format);
    try std.testing.expectEqual(win32.DXGI_FORMAT.B8G8R8A8_UNORM_SRGB, render_target_view_format);
    try std.testing.expectEqual(win32.DXGI_FORMAT.B8G8R8A8_UNORM, render_target_format);
}
