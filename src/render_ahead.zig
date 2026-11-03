//! One pending CPU canvas, separate from the immutable in-flight DMA snapshot.
//! A pending canvas must be submitted before it can be overwritten.
const std = @import("std");

pub const State = struct {
    ready: bool = false,
    full: bool = true,
    animated: bool = false,
    last_render: u64 = 0,

    pub fn due(self: State, now: u64, dirty: bool) bool {
        return self.dueAt(now, dirty, 16);
    }

    pub fn dueAt(self: State, now: u64, dirty: bool, minimum_interval: u64) bool {
        return !self.ready and dirty and now -| self.last_render >= minimum_interval;
    }

    pub fn rendered(self: *State, now: u64, full: bool, animated: bool) void {
        std.debug.assert(!self.ready);
        self.* = .{ .ready = true, .full = full, .animated = animated, .last_render = now };
    }

    pub fn submitted(self: *State) void {
        std.debug.assert(self.ready);
        self.ready = false;
    }
};

test "rendering the next canvas preserves the in-flight immutable snapshot" {
    const presentation = @import("presentation.zig");
    var canvas: [8 * 4]u16 = @splat(1);
    var snapshot: [8 * 4]u16 align(4) = undefined;
    var dma: presentation.State = .{};
    var queue: State = .{};
    try presentation.pack(&canvas, 8, 4, .{ .x = 0, .y = 0, .width = 8, .height = 4 }, &snapshot);
    try dma.prepare();
    try dma.commit(0);
    try std.testing.expect(queue.due(16, true));
    @memset(&canvas, 2);
    queue.rendered(16, true, true);
    try std.testing.expect(!queue.due(32, true));
    try std.testing.expectError(error.Owned, dma.prepare());
    for (snapshot) |pixel| try std.testing.expectEqual(1, pixel);
    _ = try dma.observe(20, 100, .{ .eof = true });
    _ = try dma.observe(21, 100, .{ .disable_done = true });
    try std.testing.expect(!dma.owned());
    try presentation.pack(&canvas, 8, 4, .{ .x = 0, .y = 0, .width = 8, .height = 4 }, &snapshot);
    queue.submitted();
    for (snapshot) |pixel| try std.testing.expectEqual(2, pixel);
    try std.testing.expect(queue.due(32, true));
}

test "arbitrary completion delays retain exactly one rendered canvas" {
    for (1..100) |latency| {
        var queue: State = .{};
        var owned_until: usize = 0;
        var rendered: usize = 0;
        var submitted: usize = 0;
        for (0..1000) |now| {
            if (queue.ready and now >= owned_until) {
                queue.submitted();
                submitted += 1;
                owned_until = now + latency;
            }
            if (queue.due(now, true)) {
                queue.rendered(now, now % 2 == 0, true);
                rendered += 1;
            }
            try std.testing.expect(rendered >= submitted and rendered <= submitted + 1);
        }
    }
}

test "producer can prepare early for a measured refresh without overwriting pending work" {
    var queue: State = .{};
    try std.testing.expect(!queue.dueAt(10, true, 11));
    try std.testing.expect(queue.dueAt(11, true, 11));
    queue.rendered(11, false, true);
    try std.testing.expect(!queue.dueAt(100, true, 11));
    queue.submitted();
    try std.testing.expect(queue.dueAt(100, true, 11));
    try std.testing.expect(!queue.dueAt(100, false, 11));
}
