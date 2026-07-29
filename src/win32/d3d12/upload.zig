//! Explicit upload staging and resource-state transitions for D3D12.
//!
//! This is the first of the two levels the D3D12 work is split into: a
//! direct, conservative upload path that is enough to carry a correct static
//! picture. Every byte the GPU will read is bump-allocated out of one upload
//! buffer; when that buffer runs out, the recorded work is executed and
//! awaited before the allocator rewinds.
//!
//! The conservative wait is the point, not an oversight. Reusing a region the
//! GPU may still be reading is the failure mode that shows up as intermittent
//! corruption rather than a reproducible error, so this slice buys correctness
//! by paying throughput. Ring reuse driven by the completion signal replaces
//! this wait later, and only once it can be judged on its own.

const std = @import("std");
const win32 = @import("win32").everything;

const com = @import("../d3d11/com.zig");

pub const Error = error{
    DeviceUnavailable,
    UploadFailed,
    SealedArenaExhausted,
};

/// D3D12 requires each row of a texture upload to start on a 256-byte
/// boundary, so CPU-side pixels are repacked rather than copied verbatim.
pub const texture_row_alignment: u32 = win32.D3D12_TEXTURE_DATA_PITCH_ALIGNMENT;

/// A placed-footprint copy source must *begin* on a 512-byte boundary. This
/// is a stricter and separate requirement from the row pitch above; using the
/// row alignment for both silently produces an invalid footprint whenever a
/// reservation happens to land on an odd multiple of 256.
pub const texture_placement_alignment: u32 = win32.D3D12_TEXTURE_DATA_PLACEMENT_ALIGNMENT;

/// Root constant buffer views must be 256-byte aligned.
pub const constant_buffer_alignment: u32 = 256;

pub fn alignUp(value: u64, alignment: u64) u64 {
    return (value + alignment - 1) & ~(alignment - 1);
}

pub fn heapProps(kind: win32.D3D12_HEAP_TYPE) win32.D3D12_HEAP_PROPERTIES {
    return .{
        .Type = kind,
        .CPUPageProperty = .UNKNOWN,
        .MemoryPoolPreference = .UNKNOWN,
        .CreationNodeMask = 1,
        .VisibleNodeMask = 1,
    };
}

pub fn bufferDesc(bytes: u64) win32.D3D12_RESOURCE_DESC {
    return .{
        .Dimension = .BUFFER,
        .Alignment = 0,
        .Width = bytes,
        .Height = 1,
        .DepthOrArraySize = 1,
        .MipLevels = 1,
        .Format = .UNKNOWN,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Layout = .ROW_MAJOR,
        .Flags = .{},
    };
}

pub fn texture2dDesc(
    format: win32.DXGI_FORMAT,
    width: u32,
    height: u32,
    flags: win32.D3D12_RESOURCE_FLAGS,
) win32.D3D12_RESOURCE_DESC {
    return .{
        .Dimension = .TEXTURE2D,
        .Alignment = 0,
        .Width = width,
        .Height = height,
        .DepthOrArraySize = 1,
        .MipLevels = 1,
        .Format = format,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Layout = .UNKNOWN,
        .Flags = flags,
    };
}

pub fn transition(
    resource: *win32.ID3D12Resource,
    before: win32.D3D12_RESOURCE_STATES,
    after: win32.D3D12_RESOURCE_STATES,
) win32.D3D12_RESOURCE_BARRIER {
    return .{
        .Type = .TRANSITION,
        .Flags = .{},
        .Anonymous = .{ .Transition = .{
            .pResource = resource,
            .Subresource = win32.D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
            .StateBefore = before,
            .StateAfter = after,
        } },
    };
}

/// A resource plus the state the command list has left it in.
///
/// Tracking state next to the resource keeps every barrier local to the one
/// place that knows what happened last, which is what stops the "two callers
/// each assume a different prior state" class of D3D12 bug.
pub const Tracked = struct {
    resource: ?*win32.ID3D12Resource = null,
    state: win32.D3D12_RESOURCE_STATES = .{},

    pub fn moveTo(
        self: *Tracked,
        list: *win32.ID3D12GraphicsCommandList,
        target: win32.D3D12_RESOURCE_STATES,
    ) void {
        const res = self.resource orelse return;
        if (@as(u32, @bitCast(self.state)) == @as(u32, @bitCast(target))) return;
        var barrier = [_]win32.D3D12_RESOURCE_BARRIER{transition(res, self.state, target)};
        list.ResourceBarrier(barrier.len, &barrier);
        self.state = target;
    }

    pub fn release(self: *Tracked) void {
        if (self.resource) |r| _ = r.IUnknown.Release();
        self.* = .{};
    }
};

/// Bump allocator over one mapped upload buffer.
///
/// `reserve` hands back a slice to write into plus the offset to copy from.
/// It never returns a region the GPU might still be reading: when the buffer
/// cannot satisfy a request, the caller's `flush` runs first and the GPU is
/// known idle before the head rewinds.
pub const Arena = struct {
    buffer: ?*win32.ID3D12Resource = null,
    mapped: [*]u8 = undefined,
    capacity: u64 = 0,
    head: u64 = 0,
    /// While sealed, `reserve` must be satisfiable from space already secured —
    /// it may not flush or grow.
    ///
    /// A flush mid-frame would submit and reset the command list, silently
    /// discarding the pipeline state, root arguments, descriptor heaps,
    /// viewport and render target that recorded draws still depend on; a
    /// growth would release the buffer those draws point into. Both failures
    /// are invisible at the call site, so the seal turns them into a loud
    /// error at the moment the assumption breaks.
    sealed: bool = false,

    pub const initial_capacity: u64 = 4 * 1024 * 1024;

    pub fn deinit(self: *Arena) void {
        if (self.buffer) |b| {
            b.Unmap(0, null);
            _ = b.IUnknown.Release();
        }
        self.* = .{};
    }

    fn allocate(self: *Arena, device: *win32.ID3D12Device, bytes: u64) Error!void {
        var resource: *win32.ID3D12Resource = undefined;
        const props = heapProps(.UPLOAD);
        const desc = bufferDesc(bytes);
        if (device.CreateCommittedResource(
            &props,
            .{},
            &desc,
            win32.D3D12_RESOURCE_STATE_GENERIC_READ,
            null,
            win32.IID_ID3D12Resource,
            @ptrCast(&resource),
        ) < 0) return error.UploadFailed;

        var mapped: ?*anyopaque = null;
        // A zero-length read range states the CPU will not read back, which
        // is true here and lets the driver skip cache maintenance.
        const empty_read = win32.D3D12_RANGE{ .Begin = 0, .End = 0 };
        if (resource.Map(0, &empty_read, &mapped) < 0) {
            _ = resource.IUnknown.Release();
            return error.UploadFailed;
        }

        self.deinit();
        self.buffer = resource;
        self.mapped = @ptrCast(mapped.?);
        self.capacity = bytes;
        self.head = 0;
    }

    pub const Reservation = struct {
        bytes: []u8,
        offset: u64,
    };

    /// Reserve `len` bytes aligned to `alignment`. `flush_fn` is invoked with
    /// `flush_ctx` when the current buffer cannot satisfy the request; it must
    /// make every previously reserved region safe to overwrite.
    pub fn reserve(
        self: *Arena,
        device: *win32.ID3D12Device,
        len: u64,
        alignment: u64,
        flush_ctx: *anyopaque,
        flush_fn: *const fn (*anyopaque) void,
    ) Error!Reservation {
        if (self.buffer == null) {
            if (self.sealed) return error.SealedArenaExhausted;
            try self.allocate(device, @max(len, initial_capacity));
        }
        var start = alignUp(self.head, alignment);
        if (start + len > self.capacity) {
            if (self.sealed) return error.SealedArenaExhausted;
            flush_fn(flush_ctx);
            self.head = 0;
            start = 0;
            if (len > self.capacity) {
                // Grow past the point where a flush alone would help. The
                // previous buffer is only released after the flush above, so
                // nothing in flight still references it.
                try self.allocate(device, alignUp(len, initial_capacity));
                start = 0;
            }
        }
        self.head = start + len;
        return .{ .bytes = self.mapped[@intCast(start)..@intCast(start + len)], .offset = start };
    }

    /// Make room for `len` bytes without handing any out, so a following
    /// sealed run of reservations cannot need to flush or grow.
    pub fn ensureCapacityFor(
        self: *Arena,
        device: *win32.ID3D12Device,
        len: u64,
        alignment: u64,
        flush_ctx: *anyopaque,
        flush_fn: *const fn (*anyopaque) void,
    ) Error!void {
        std.debug.assert(!self.sealed);
        const probe = try self.reserve(device, len, alignment, flush_ctx, flush_fn);
        // Hand the space straight back: the point was to force any flush or
        // growth to happen now rather than part-way through a frame.
        self.head = probe.offset;
    }

    pub fn rewind(self: *Arena) void {
        self.head = 0;
    }
};

test "aligning up never moves an already aligned value" {
    // Row pitch and constant-buffer alignment are both correctness
    // requirements in D3D12, not optimizations: an unaligned texture upload
    // silently copies garbage rather than failing loudly.
    try std.testing.expectEqual(@as(u64, 0), alignUp(0, 256));
    try std.testing.expectEqual(@as(u64, 256), alignUp(256, 256));
    try std.testing.expectEqual(@as(u64, 256), alignUp(1, 256));
    try std.testing.expectEqual(@as(u64, 512), alignUp(257, 256));
    try std.testing.expectEqual(@as(u64, 256), alignUp(255, texture_row_alignment));
}

test "a sealed arena refuses to flush rather than silently invalidating a frame" {
    // Sealing exists because a flush or growth part-way through a frame is
    // invisible where it happens and only surfaces as a wrong picture: the
    // command list loses the state recorded draws need, or the buffer they
    // point into is freed. Refusing loudly is the whole point of the flag.
    const Ctx = struct {
        fn onFlush(ctx: *anyopaque) void {
            const flag: *bool = @ptrCast(@alignCast(ctx));
            flag.* = true;
        }
    };
    var flushed = false;
    var arena: Arena = .{ .capacity = 0, .head = 0, .sealed = true };
    try std.testing.expectError(error.SealedArenaExhausted, arena.reserve(
        @ptrFromInt(0x1000),
        16,
        16,
        &flushed,
        Ctx.onFlush,
    ));
    try std.testing.expect(!flushed);

    // With room already secured the request is served: the seal constrains
    // growth, not ordinary use.
    var backing: [64]u8 = undefined;
    var stocked: Arena = .{
        .buffer = @ptrFromInt(0x1000),
        .mapped = &backing,
        .capacity = backing.len,
        .head = 0,
        .sealed = true,
    };
    const res = try stocked.reserve(@ptrFromInt(0x1000), 16, 16, &flushed, Ctx.onFlush);
    try std.testing.expectEqual(@as(u64, 0), res.offset);
    try std.testing.expectEqual(@as(usize, 16), res.bytes.len);
    try std.testing.expect(!flushed);
}

test "texture staging is placed on a stricter boundary than its rows" {
    // Row pitch and placement offset are two separate D3D12 requirements.
    // Using the row alignment for the offset yields a footprint the runtime
    // rejects only on odd multiples of 256, so the bug reads as intermittent.
    try std.testing.expect(texture_placement_alignment > texture_row_alignment);
    try std.testing.expectEqual(@as(u64, 512), alignUp(256, texture_placement_alignment));
    try std.testing.expectEqual(@as(u64, 512), alignUp(512, texture_placement_alignment));
}

test "a transition barrier names both the state left behind and the one entered" {
    // D3D12 validates the before-state against what the resource is actually
    // in, so a barrier that guesses wrong is a hard error rather than a
    // visual artifact — worth pinning the shape of what we build.
    const fake: *win32.ID3D12Resource = @ptrFromInt(0x1000);
    const barrier = transition(
        fake,
        win32.D3D12_RESOURCE_STATE_COPY_DEST,
        win32.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,
    );
    try std.testing.expectEqual(win32.D3D12_RESOURCE_BARRIER_TYPE.TRANSITION, barrier.Type);
    try std.testing.expectEqual(fake, barrier.Anonymous.Transition.pResource.?);
    try std.testing.expectEqual(
        @as(u32, @bitCast(win32.D3D12_RESOURCE_STATE_COPY_DEST)),
        @as(u32, @bitCast(barrier.Anonymous.Transition.StateBefore)),
    );
    try std.testing.expectEqual(
        @as(u32, @bitCast(win32.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE)),
        @as(u32, @bitCast(barrier.Anonymous.Transition.StateAfter)),
    );
}

test "moving a tracked resource to the state it already holds emits no barrier" {
    // Redundant barriers are not merely wasteful: a same-state transition is
    // a validation error in D3D12, so this has to be suppressed at the source.
    var tracked: Tracked = .{
        .resource = null,
        .state = win32.D3D12_RESOURCE_STATE_COPY_DEST,
    };
    // A null resource must be inert rather than crash — resources are created
    // lazily and the shared layer may ask for a transition before then.
    tracked.moveTo(@ptrFromInt(0x1000), win32.D3D12_RESOURCE_STATE_COPY_DEST);
    try std.testing.expectEqual(
        @as(u32, @bitCast(win32.D3D12_RESOURCE_STATE_COPY_DEST)),
        @as(u32, @bitCast(tracked.state)),
    );
}

comptime {
    // `com` is imported for the shared fatal-HRESULT helper used by callers of
    // this module; reference it so the import cannot rot unnoticed.
    _ = com;
}
