const std = @import("std");

pub const vertex = ShaderPair{
    .directx = @embedFile("terminal_vertex.dxbc"),
    .spirv = @embedFile("terminal_vertex.spv"),
};
pub const pixel = ShaderPair{
    .directx = @embedFile("terminal_pixel.dxbc"),
    .spirv = @embedFile("terminal_pixel.spv"),
};
pub const image_pixel = ShaderPair{
    .directx = @embedFile("terminal_image_pixel.dxbc"),
    .spirv = @embedFile("terminal_image_pixel.spv"),
};

pub const ShaderPair = struct {
    directx: []const u8,
    spirv: []const u8,
};

test "every runtime shader entry has valid DirectX and SPIR-V assets" {
    inline for (.{ vertex, pixel, image_pixel }) |pair| {
        try std.testing.expect(pair.directx.len > 4);
        try std.testing.expectEqualStrings("DXBC", pair.directx[0..4]);
        try std.testing.expect(pair.spirv.len > 4);
        try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0x23, 0x07 }, pair.spirv[0..4]);
    }
}

test "SPIR-V resource bindings remain explicit and collision-free" {
    const source = @embedFile("terminal.hlsl");
    const contract = [_][]const u8{
        "VK_BINDING(0) cbuffer GridConfig : register(b0)",
        "VK_BINDING(1) StructuredBuffer<Cell> cells : register(t0);",
        "VK_BINDING(2) Texture2D<float4> glyph_texture : register(t1);",
        "VK_BINDING(3) Texture2D<float4> bg_image : register(t2);",
        "VK_BINDING(4) SamplerState bg_sampler : register(s0);",
        "VK_BINDING(5) Texture2D<float4> inline_image : register(t3);",
        "VK_BINDING(0) cbuffer ImageConfig : register(b0)",
    };
    for (contract) |declaration| {
        try std.testing.expect(std.mem.indexOf(u8, source, declaration) != null);
    }
}
