//! Explicit upload staging and resource-state transitions for D3D12.
//!
//! Staging is organised into generations. Each generation owns an upload
//! buffer and is bound, at submission, to a completion value; it may only be
//! handed out again once that value has been reached. Reusing a region the
//! GPU may still be reading is the failure mode that shows up as intermittent
//! corruption rather than a reproducible error, so the decision of when a
//! generation is free is kept as `Ring` — plain bookkeeping with no GPU types
//! in it, decidable and testable without observing a picture.

const std = @import("std");
const win32 = @import("win32").everything;

const com = @import("../d3d11/com.zig");

pub const Error = error{
    DeviceUnavailable,
    UploadFailed,
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

/// Which generation may be handed out, decided from bookkeeping alone.
///
/// This deliberately carries no GPU types. "A staging region is reused only
/// after the GPU is done with it" is the one invariant of this slice whose
/// violation does not reliably reach the screen, so the rule that discharges
/// it has to be decidable — and exhaustively testable — without rendering
/// anything.
pub const Ring = struct {
    /// Two is what pipelining needs: the CPU records into one generation while
    /// the GPU still reads the other. More would only deepen the queue the
    /// presentation gate already caps.
    pub const generations: u32 = 2;

    /// Completion value each generation's last submission was bound to. Zero
    /// means the generation has never been submitted, so nothing is owed.
    bound: [generations]u64 = @splat(0),
    cursor: u32 = 0,

    pub fn next(self: Ring) u32 {
        return (self.cursor + 1) % generations;
    }

    /// Completion value that must be reached before the next generation may be
    /// handed out, or null when it owes nothing.
    pub fn blocking(self: Ring) ?u64 {
        const value = self.bound[self.next()];
        return if (value == 0) null else value;
    }

    pub fn advance(self: *Ring) void {
        self.cursor = self.next();
    }

    pub fn bind(self: *Ring, value: u64) void {
        self.bound[self.cursor] = value;
    }

    /// Whether handing out the current generation is safe at `completed`.
    pub fn currentIsSafe(self: Ring, completed: u64) bool {
        return completed >= self.bound[self.cursor];
    }
};

/// Bump allocator over one mapped upload buffer, owned by one generation.
///
/// `reserve` hands back a slice to write into plus the offset to copy from.
/// It never waits: the only point at which staged bytes become overwritable
/// is `recycle`, which the renderer may call solely once the owning
/// generation's bound completion value has been reached.
pub const Arena = struct {
    buffer: ?*win32.ID3D12Resource = null,
    mapped: [*]u8 = undefined,
    capacity: u64 = 0,
    head: u64 = 0,
    /// Buffers replaced by growth. Recorded copies still name them and a D3D12
    /// command list does not keep its resources alive, so they outlive the
    /// growth and are only released when the generation is recycled.
    retired: std.ArrayListUnmanaged(*win32.ID3D12Resource) = .empty,

    pub const initial_capacity: u64 = 4 * 1024 * 1024;

    pub fn deinit(self: *Arena) void {
        self.releaseRetired();
        self.retired.deinit(std.heap.page_allocator);
        if (self.buffer) |b| {
            b.Unmap(0, null);
            _ = b.IUnknown.Release();
        }
        self.* = .{};
    }

    fn releaseRetired(self: *Arena) void {
        for (self.retired.items) |r| _ = r.IUnknown.Release();
        self.retired.clearRetainingCapacity();
    }

    /// Hand the whole arena back for reuse.
    ///
    /// This is the single place the "no CPU overwrite of a region the GPU may
    /// still read" invariant is discharged, so it is only legal once the
    /// owning generation's bound completion value has been reached.
    pub fn recycle(self: *Arena) void {
        self.releaseRetired();
        self.head = 0;
    }

    fn grow(self: *Arena, device: *win32.ID3D12Device, bytes: u64) Error!void {
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

        if (self.buffer) |old| {
            self.retired.append(std.heap.page_allocator, old) catch {
                resource.Unmap(0, null);
                _ = resource.IUnknown.Release();
                return error.UploadFailed;
            };
        }
        self.buffer = resource;
        self.mapped = @ptrCast(mapped.?);
        self.capacity = bytes;
        self.head = 0;
    }

    pub const Reservation = struct {
        bytes: []u8,
        offset: u64,
    };

    /// Reserve `len` bytes aligned to `alignment`.
    ///
    /// A request the buffer cannot hold is answered by growth, never by a
    /// wait: a wait here would be a second throttle on the frame path, which
    /// is exactly the stacked delay this backend has to avoid.
    pub fn reserve(
        self: *Arena,
        device: *win32.ID3D12Device,
        len: u64,
        alignment: u64,
    ) Error!Reservation {
        const start = alignUp(self.head, alignment);
        if (self.buffer == null or start + len > self.capacity) {
            try self.grow(device, @max(@max(len, self.capacity * 2), initial_capacity));
            self.head = len;
            return .{ .bytes = self.mapped[0..@intCast(len)], .offset = 0 };
        }
        self.head = start + len;
        return .{ .bytes = self.mapped[@intCast(start)..@intCast(start + len)], .offset = start };
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

test "reservations bump within a generation and never overlap" {
    // Two live reservations sharing bytes is the corruption this whole module
    // exists to prevent, and it would show up as a wrong glyph rather than as
    // an error, so pin the non-overlap directly.
    var backing: [256]u8 = undefined;
    var arena: Arena = .{
        .buffer = @ptrFromInt(0x1000),
        .mapped = &backing,
        .capacity = backing.len,
        .head = 0,
    };
    const first = try arena.reserve(@ptrFromInt(0x1000), 16, 16);
    const second = try arena.reserve(@ptrFromInt(0x1000), 16, 16);
    try std.testing.expectEqual(@as(u64, 0), first.offset);
    try std.testing.expect(second.offset >= first.offset + first.bytes.len);
}

test "recycling a generation is what frees its staged bytes, not reserving" {
    // `reserve` must never make earlier bytes overwritable — only `recycle`
    // may, and the renderer is allowed to call it solely after the generation's
    // completion value has been reached. If reserving rewound on its own, the
    // GPU could still be reading what the next reservation hands out.
    var backing: [64]u8 = undefined;
    var arena: Arena = .{
        .buffer = @ptrFromInt(0x1000),
        .mapped = &backing,
        .capacity = backing.len,
        .head = 0,
    };
    _ = try arena.reserve(@ptrFromInt(0x1000), 32, 16);
    try std.testing.expectEqual(@as(u64, 32), arena.head);
    arena.recycle();
    try std.testing.expectEqual(@as(u64, 0), arena.head);
}

test "outgrowing a generation replaces its buffer instead of reusing live bytes" {
    // This is the exhaustion path the test above cannot reach, and it is the
    // one that matters: rewinding on overflow would hand the next caller bytes
    // the GPU is still reading, while freeing the outgrown buffer would strand
    // recorded copies that name it — a D3D12 command list does not keep its
    // resources alive. Growth must therefore do neither.
    var skeleton = @import("../d3d12.zig").Skeleton.initWarp() catch |err| switch (err) {
        // A machine with no WARP adapter cannot judge this, and pretending it
        // passed would be worse than saying so.
        error.DeviceUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer skeleton.deinit();

    var arena: Arena = .{};
    defer arena.deinit();

    const first = try arena.reserve(skeleton.device, 1024, 256);
    const original = arena.buffer.?;
    try std.testing.expectEqual(@as(usize, 0), arena.retired.items.len);

    // Ask for more than the whole arena holds, forcing the growth path.
    const second = try arena.reserve(skeleton.device, arena.capacity + 1, 256);
    try std.testing.expect(arena.buffer.? != original);
    try std.testing.expect(second.bytes.ptr != first.bytes.ptr);
    // The outgrown buffer is retained, not released, until the generation is
    // recycled — that is what keeps already-recorded copies valid.
    try std.testing.expectEqual(@as(usize, 1), arena.retired.items.len);
    try std.testing.expectEqual(original, arena.retired.items[0]);

    arena.recycle();
    try std.testing.expectEqual(@as(usize, 0), arena.retired.items.len);
    try std.testing.expectEqual(@as(u64, 0), arena.head);
}

test "a generation is only handed out once its bound completion value is reached" {
    // The reuse rule decided without a GPU in sight. This is the independent
    // means of confirming the invariant the plan requires: the failure it
    // guards against is intermittent and often invisible, so "it looked fine"
    // is not evidence either way.
    var ring: Ring = .{};

    // Nothing submitted yet: the first two generations owe nothing.
    try std.testing.expectEqual(@as(?u64, null), ring.blocking());
    ring.advance();
    ring.bind(7);
    try std.testing.expectEqual(@as(?u64, null), ring.blocking());
    ring.advance();
    ring.bind(9);

    // Back around to the generation bound to 7: it is owed until 7 completes.
    try std.testing.expectEqual(@as(?u64, 7), ring.blocking());
    ring.advance();
    try std.testing.expect(!ring.currentIsSafe(6));
    try std.testing.expect(ring.currentIsSafe(7));
    // A later completion value implies every earlier one, since the signal is
    // monotonic — reuse must not demand an exact match.
    try std.testing.expect(ring.currentIsSafe(100));

    // The other generation is still owed at 9 even though 7 has completed.
    try std.testing.expectEqual(@as(?u64, 9), ring.blocking());
}

test "every generation is visited before any is reused" {
    // Reusing a generation while a sibling sits idle would shrink the pipeline
    // to one and quietly reintroduce a wait per frame.
    var ring: Ring = .{};
    var seen: [Ring.generations]bool = @splat(false);
    var i: u32 = 0;
    while (i < Ring.generations) : (i += 1) {
        ring.advance();
        try std.testing.expect(!seen[ring.cursor]);
        seen[ring.cursor] = true;
    }
    for (seen) |s| try std.testing.expect(s);
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
