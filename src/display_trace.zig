//! Optional bounded RAM timing evidence for development qualification.
//! Writes are four integers; the host reads the ring after each animation.
const std = @import("std");
pub const capacity = 2048;
pub const Kind = enum(u32) { render = 1, commit = 2, release = 3, retarget = 4, model = 5, motion = 6, flow = 7, covers = 8, model_v2 = 9, library_work = 10 };
/// Versioned separately from legacy kind 5, which reserved only three screen
/// bits. Existing timing captures remain readable after adding device menus.
pub const Model = packed struct(u32) {
    rows: u11,
    selection: u15,
    screen: u4,
    volume_moving: bool,
    moving: bool,
};
/// Masks follow the seven visible models in paint order. Missing means a
/// completed negative cache entry; an absent ready bit alone means loading.
pub const Covers = packed struct(u32) {
    present: u7 = 0,
    ready: u7 = 0,
    missing: u7 = 0,
    center_present: bool = false,
    center_ready: bool = false,
    destination_ready: bool = false,
    reserved: u8 = 0,
};
pub const Entry = extern struct { sequence: u32, at: u32, kind: Kind, value: u32 };
pub const Ring = struct {
    entries: [capacity]Entry = @splat(.{ .sequence = 0, .at = 0, .kind = .render, .value = 0 }),
    next: u32 = 0,

    pub fn record(self: *Ring, kind: Kind, at: u32, value: u32) void {
        self.entries[self.next % capacity] = .{ .sequence = self.next, .at = at, .kind = kind, .value = value };
        self.next +%= 1;
    }
};
pub var ring: Ring = .{};

test "bounded timing evidence overwrites oldest records and preserves clock wrap" {
    var trace: Ring = .{};
    for (0..capacity + 50) |i| trace.record(.commit, 0xfffffff0 +% @as(u32, @intCast(i)), @intCast(i));
    try std.testing.expectEqual(capacity + 50, trace.next);
    for (50..capacity + 50) |i| {
        const entry = trace.entries[i % capacity];
        try std.testing.expectEqual(i, entry.sequence);
        try std.testing.expectEqual(0xfffffff0 +% @as(u32, @intCast(i)), entry.at);
        try std.testing.expectEqual(i, entry.value);
    }
}

pub fn record(kind: Kind, at: u32, value: u32) void {
    const root = @import("root");
    const enabled = @import("builtin").is_test or
        (if (@hasDecl(root, "gain_options")) root.gain_options.display_trace else false);
    if (comptime !enabled) return;
    if (comptime @import("builtin").cpu.arch == .mipsel) {
        const x = @import("x1000.zig");
        const status = x.Interrupts.disableCpu();
        defer x.Interrupts.restoreCpu(status);
        ring.record(kind, at, value);
    } else ring.record(kind, at, value);
}
