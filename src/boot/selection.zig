//! Two immutable candidates; no execution or filesystem mutation is permitted.
const image = @import("image.zig");
pub const Slot = enum { current, previous };
pub const Selection = struct { slot: Slot, header: image.Header, first_failure: ?anyerror = null };

pub fn choose(reader: anytype, prefer_previous: bool) !Selection {
    const first: Slot = if (prefer_previous) .previous else .current;
    const second: Slot = if (prefer_previous) .current else .previous;
    const header = reader.load(first) catch |failure| {
        const fallback = reader.load(second) catch return failure;
        return .{ .slot = second, .header = fallback, .first_failure = failure };
    };
    return .{ .slot = first, .header = header };
}

const Fake = struct {
    bad: [2]bool,
    calls: [2]Slot = undefined,
    count: usize = 0,
    pub fn load(self: *@This(), slot: Slot) !image.Header {
        self.calls[self.count] = slot;
        self.count += 1;
        if (self.bad[@backingInt(slot)]) return if (slot == .current) error.CorruptCurrent else error.CorruptPrevious;
        return .{ .size = 1, .checksum = 0 };
    }
};

test "only a validated candidate is selected, and both failures retain the first reason" {
    const std = @import("std");
    for ([_]bool{ false, true }) |previous| for ([_]bool{ false, true }) |current_bad| for ([_]bool{ false, true }) |previous_bad| {
        var reader = Fake{ .bad = .{ current_bad, previous_bad } };
        const first: Slot = if (previous) .previous else .current;
        if (current_bad and previous_bad) {
            if (previous) try std.testing.expectError(error.CorruptPrevious, choose(&reader, previous)) else try std.testing.expectError(error.CorruptCurrent, choose(&reader, previous));
            try std.testing.expectEqual(2, reader.count);
        } else {
            const selected = try choose(&reader, previous);
            const expected = if (reader.bad[@backingInt(first)]) (if (previous) Slot.current else Slot.previous) else first;
            try std.testing.expectEqual(expected, selected.slot);
            try std.testing.expectEqual(if (expected == first) @as(usize, 1) else 2, reader.count);
            try std.testing.expectEqual(expected != first, selected.first_failure != null);
        }
        try std.testing.expectEqual(first, reader.calls[0]);
    };
}
