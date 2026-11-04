//! Presentation pacing is independent of when the next canvas finishes painting.
const std = @import("std");

pub const Pacer = struct {
    last: ?u32 = null,

    pub fn deadline(self: Pacer, now: u32, period: u31) ?u32 {
        const previous = self.last orelse return null;
        return if (now -% previous < period) previous +% period else null;
    }

    pub fn committed(self: *Pacer, now: u32) void {
        self.last = now;
    }
};

test "render ahead never submits faster than refresh and missed frames never burst" {
    const period = 87_480;
    var random = std.Random.DefaultPrng.init(0x50414345);
    const rng = random.random();
    for (0..100) |_| {
        var pacer = Pacer{};
        var now = rng.int(u32);
        for (0..1000) |_| {
            const previous = pacer.last;
            now +%= rng.uintLessThan(u32, period * 3);
            const commit = pacer.deadline(now, period) orelse now;
            if (previous) |at| try std.testing.expect(commit -% at >= period);
            try std.testing.expect(commit -% now <= period);
            pacer.committed(commit);
            now = commit;
        }
    }
}

test "idle, timer wrap and long pauses cannot leave a stale future deadline" {
    var pacer = Pacer{};
    try std.testing.expect(pacer.deadline(0, 100) == null);
    pacer.committed(0xfffffff0);
    try std.testing.expectEqual(@as(u32, 84), pacer.deadline(10, 100).?);
    try std.testing.expect(pacer.deadline(84, 100) == null);
    try std.testing.expect(pacer.deadline(0x80000000, 100) == null);
}
