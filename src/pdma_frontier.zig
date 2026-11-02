//! X1000 linked-DMA observation. CDOA is a descriptor offset, not a
//! completion counter. Validate it against DSA before releasing any buffer.
const std = @import("std");

pub const Error = error{InvalidDescriptorOffset};

pub const Sample = struct { link_before: u8, source: u32, link_after: u8 };

/// Return the descriptor at the completion frontier. A source at the end of
/// the old buffer and a source inside the newly fetched buffer describe the
/// same frontier. A changing link is retried without acknowledging the event.
pub fn observe(sample: Sample, descriptor_count: u8, buffers: []const u32, chunk_bytes: u32) Error!?u7 {
    if (sample.link_before != sample.link_after) return null;
    if (descriptor_count == 0 or descriptor_count > 128 or buffers.len < 2 or buffers.len > 4 or descriptor_count % buffers.len != 0 or chunk_bytes == 0) return error.InvalidDescriptorOffset;
    const offset = sample.link_before;
    if (offset & 1 != 0 or @as(u16, offset) / 2 >= descriptor_count) return error.InvalidDescriptorOffset;
    const current: u8 = offset / 2;
    const previous: u8 = if (current == 0) descriptor_count - 1 else current - 1;
    const source = sample.source & physical_mask;
    // CDOA can describe the current fetch or its successor in the transfer
    // handoff window. DSA selects which candidate actually owns the buffer.
    // Prefer an in-buffer observation over an end boundary (adjacent buffers).
    for ([_]u8{ current, previous }) |active| {
        const start = buffers[active % buffers.len] & physical_mask;
        if (source >= start and source - start < chunk_bytes) return @intCast(active);
    }
    for ([_]u8{ current, previous }) |active| {
        const start = buffers[active % buffers.len] & physical_mask;
        if (@as(u64, start) + chunk_bytes == source) return @intCast(if (active + 1 == descriptor_count) 0 else active + 1);
    }
    // DSA may change before CDOA while fetching a descriptor. A foreign source
    // is never completion evidence; the caller retries a bounded sample.
    return null;
}

pub const Cursor = struct {
    frontier: u7 = 0,
    unresolved_since: ?u32 = null,

    pub fn unresolved(self: *Cursor, now: u32, timeout: u32) error{DmaObservationTimeout}!void {
        if (self.unresolved_since == null) self.unresolved_since = now;
        if (now -% self.unresolved_since.? >= timeout) return error.DmaObservationTimeout;
    }

    pub fn update(self: *Cursor, next: u7) ?u7 {
        self.unresolved_since = null;
        if (next == self.frontier) return null;
        self.frontier = next;
        return next;
    }
};

const physical_mask: u32 = 0x1fffffff;

test "completion and descriptor-fetch windows produce one frontier, including 120-link wrap" {
    const addresses = [_]u32{ 0xa0100000, 0xa0180000, 0xa0200000 };
    var cursor = Cursor{};
    for (0..360) |index| {
        const active: u8 = @intCast(index % 120);
        const successor: u8 = (active + 1) % 120;
        const after: u8 = (successor + 1) % 120;
        const source = addresses[active % 3] & physical_mask;
        const before = (try observe(.{ .link_before = successor * 2, .source = source + 256, .link_after = successor * 2 }, 120, &addresses, 1024)).?;
        try std.testing.expectEqual(@as(u7, @intCast(active)), before);
        try std.testing.expect(cursor.update(before) == null);
        const complete = (try observe(.{
            .link_before = successor * 2,
            .source = source + 1024,
            .link_after = successor * 2,
        }, 120, &addresses, 1024)).?;
        try std.testing.expectEqual(@as(?u7, @intCast(successor)), cursor.update(complete));
        const fetched = (try observe(.{
            .link_before = after * 2,
            .source = addresses[successor % 3] + 256,
            .link_after = after * 2,
        }, 120, &addresses, 1024)).?;
        try std.testing.expect(cursor.update(fetched) == null);
        try std.testing.expect((try observe(.{
            .link_before = successor * 2,
            .source = addresses[successor % 3],
            .link_after = after * 2,
        }, 120, &addresses, 1024)) == null);
    }
}

test "captured delayed polling trace no longer double counts copied links 13 and 14" {
    const playback = @import("playback.zig");

    const addresses = [_]u32{ 0xa0100000, 0xa0180000, 0xa0200000 };
    var state = try playback.State.init(.{ .buffer_count = 3, .descriptor_count = 120, .total_chunks = 40 });
    // Captured sequence after volume I2C: CDOA 13 while 11 complete, then
    // CDOA 14 twice. DSA in the active buffer distinguishes copied links from
    // transfer completion; this deterministic register model covers both views.
    for (1..12) |_| {
        const step = try state.advance(state.nextDescriptor());
        if (step.refill) |refill| try state.completeRefill(refill);
    }
    var cursor = Cursor{ .frontier = 11 };
    const links = [_]u8{ 13, 14, 14, 15 };
    for (links) |link| {
        const active = link - 1;
        const frontier = (try observe(.{
            .link_before = link * 2,
            .source = addresses[active % 3] + 256,
            .link_after = link * 2,
        }, 120, &addresses, 131072)).?;
        if (cursor.update(frontier)) |next| {
            const count = try state.completionsTo(next);
            for (0..count) |_| {
                const step = try state.advance(state.nextDescriptor());
                if (step.refill) |refill| try state.completeRefill(refill);
            }
        }
    }
    try std.testing.expectEqual(@as(u32, 14), state.chunks_completed);
}

test "invalid or incoherent DMA snapshots never release memory" {
    const addresses = [_]u32{ 0xa0100000, 0xa0180000, 0xa0200000 };
    try std.testing.expect((try observe(.{ .link_before = 2, .source = 0xdeadbeef, .link_after = 2 }, 120, &addresses, 1024)) == null);
    try std.testing.expectError(error.InvalidDescriptorOffset, observe(.{
        .link_before = 3,
        .source = 0x100000,
        .link_after = 3,
    }, 120, &addresses, 1024));
    try std.testing.expectError(error.InvalidDescriptorOffset, observe(.{
        .link_before = 240,
        .source = 0x100000,
        .link_after = 240,
    }, 120, &addresses, 1024));
}

test "an incoherent source times out across wrap rather than keeping playback alive forever" {
    var cursor = Cursor{};
    try cursor.unresolved(0xfffffff0, 32);
    try cursor.unresolved(0x0f, 32);
    try std.testing.expectError(error.DmaObservationTimeout, cursor.unresolved(0x10, 32));
    _ = cursor.update(1);
    try std.testing.expect(cursor.unresolved_since == null);
    try cursor.unresolved(0x20, 32);
}

test "captured 44.1 kHz source 0x180080 and CDOA 0x02 select active descriptor one" {
    const buffers = [_]u32{ 0xa0100000, 0xa0180000, 0xa0200000 };
    const sample = Sample{ .link_before = 2, .source = 0x00180080, .link_after = 2 };
    try std.testing.expectEqual(@as(?u7, 1), try observe(sample, 120, &buffers, 8820));
    // The fetched successor may already be copied into CDOA; DSA continues
    // to establish ownership in either register-update window.
    try std.testing.expectEqual(@as(?u7, 1), try observe(.{ .link_before = 4, .source = 0x00180080, .link_after = 4 }, 120, &buffers, 8820));
}
