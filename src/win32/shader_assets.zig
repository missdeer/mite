const std = @import("std");

pub const vertex = ShaderTargets{
    .dxbc = @embedFile("terminal_vertex.dxbc"),
    .dxil = @embedFile("terminal_vertex.dxil"),
    .spirv = @embedFile("terminal_vertex.spv"),
};
pub const pixel = ShaderTargets{
    .dxbc = @embedFile("terminal_pixel.dxbc"),
    .dxil = @embedFile("terminal_pixel.dxil"),
    .spirv = @embedFile("terminal_pixel.spv"),
};
pub const image_pixel = ShaderTargets{
    .dxbc = @embedFile("terminal_image_pixel.dxbc"),
    .dxil = @embedFile("terminal_image_pixel.dxil"),
    .spirv = @embedFile("terminal_image_pixel.spv"),
};
pub const present_pixel = @embedFile("terminal_present_pixel.dxbc");

pub const ShaderTargets = struct {
    /// Shader Model 5 bytecode consumed by D3D11, which rejects Shader Model 6.
    dxbc: []const u8,
    /// Signed Shader Model 6 bytecode consumed by D3D12, which rejects Shader Model 5.
    dxil: []const u8,
    spirv: []const u8,
};

/// Both FXC and DXC emit the same DXBC container; only the parts inside differ.
/// Bytes 4..20 hold the signing digest, which stays zeroed when the compiler
/// cannot sign.
const container_digest = struct {
    const offset = 4;
    const len = 16;
};

fn containerHasPart(container: []const u8, fourcc: *const [4]u8) bool {
    if (container.len < 32) return false;
    const part_count = std.mem.readInt(u32, container[28..32], .little);
    for (0..part_count) |index| {
        // Every offset widens to usize before any arithmetic: these are u32
        // values read out of the file, so `offset + 4` in u32 would wrap on a
        // malformed container and slip past the bounds check.
        const table_offset = 32 + index * 4;
        if (table_offset + 4 > container.len) return false;
        const part_offset: usize = std.mem.readInt(u32, container[table_offset..][0..4], .little);
        if (part_offset + 4 > container.len) return false;
        if (std.mem.eql(u8, container[part_offset..][0..4], fourcc)) return true;
    }
    return false;
}

fn spirvContainsOpcode(spirv: []const u8, opcode: u16) bool {
    if (spirv.len < 20 or spirv.len % 4 != 0) return false;
    var offset: usize = 20;
    while (offset < spirv.len) {
        const instruction = std.mem.readInt(u32, spirv[offset..][0..4], .little);
        const word_count = instruction >> 16;
        if (word_count == 0 or offset + word_count * 4 > spirv.len) return false;
        if (@as(u16, @truncate(instruction)) == opcode) return true;
        offset += word_count * 4;
    }
    return false;
}

test "every runtime shader entry has valid DirectX and SPIR-V assets" {
    inline for (.{ vertex, pixel, image_pixel }) |targets| {
        try std.testing.expect(targets.dxbc.len > 4);
        try std.testing.expectEqualStrings("DXBC", targets.dxbc[0..4]);
        try std.testing.expect(targets.dxil.len > 4);
        try std.testing.expectEqualStrings("DXBC", targets.dxil[0..4]);
        try std.testing.expect(targets.spirv.len > 4);
        try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0x23, 0x07 }, targets.spirv[0..4]);
        try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x01, 0x00 }, targets.spirv[4..8]);
    }
}

test "D3D11 presentation shader has valid bytecode" {
    try std.testing.expect(present_pixel.len > 4);
    try std.testing.expectEqualStrings("DXBC", present_pixel[0..4]);
}

test "OpenGL SPIR-V uses combined sampled images" {
    // GL_ARB_gl_spirv rejects OpTypeSampler and shader-side image/sampler
    // pairing. The build must combine each sampled texture before embedding it.
    inline for (.{ pixel.spirv, image_pixel.spirv }) |spirv| {
        try std.testing.expect(!spirvContainsOpcode(spirv, 26)); // OpTypeSampler
        try std.testing.expect(spirvContainsOpcode(spirv, 27)); // OpTypeSampledImage
    }
}

test "D3D12 assets carry Shader Model 6 bytecode and D3D11 assets do not" {
    // The two DirectX targets share a container format, so the part inside is
    // the only thing that distinguishes them. Mixing them up would hand D3D11
    // bytecode it rejects, which is exactly how the Shader Model 6 upgrade
    // failed the first time.
    inline for (.{ vertex, pixel, image_pixel }) |targets| {
        try std.testing.expect(containerHasPart(targets.dxil, "DXIL"));
        try std.testing.expect(!containerHasPart(targets.dxbc, "DXIL"));
    }
}

test "D3D12 assets are signed" {
    // D3D12 refuses unsigned DXIL unless the machine is in developer mode, so
    // an unsigned asset would pass the build and only fail on other people's
    // machines.
    inline for (.{ vertex, pixel, image_pixel }) |targets| {
        const digest = targets.dxil[container_digest.offset..][0..container_digest.len];
        try std.testing.expect(!std.mem.allEqual(u8, digest, 0));
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
