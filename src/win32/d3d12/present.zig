//! D3D12 bindings for the shared DirectComposition surface.

const std = @import("std");
const win32 = @import("win32").everything;

const dcomp = @import("../dcomp.zig");
const pipeline = @import("pipeline.zig");

pub const Error = dcomp.Error;
pub const DXGI_STATUS_OCCLUDED = dcomp.DXGI_STATUS_OCCLUDED;
pub const Surface = dcomp.Surface;

test "presentation reuses the same swap-chain format the grid renders into" {
    try std.testing.expectEqual(win32.DXGI_FORMAT.B8G8R8A8_UNORM, pipeline.render_target_format);
}
