//! The command may cause immediate card data. DMA must be enabled before an
//! unrelated task can run between those two controller writes.
const std = @import("std");

pub fn start(io: anytype, data: bool) void {
    const status = io.mask();
    defer io.restore(status);
    io.beginCommand();
    if (data) io.dma();
}

const Model = struct {
    interrupts: bool = true,
    delayed: bool = false,
    data_lost: bool = false,
    armed: bool = false,

    fn mask(self: *@This()) bool {
        const old = self.interrupts;
        self.interrupts = false;
        return old;
    }

    fn restore(self: *@This(), old: bool) void {
        self.interrupts = old;
    }

    fn beginCommand(self: *@This()) void {
        if (self.interrupts and self.delayed) self.data_lost = true;
    }

    fn dma(self: *@This()) void {
        self.armed = true;
    }
};

test "UI preemption cannot split command and DMA startup" {
    var original: Model = .{ .delayed = true };
    original.beginCommand();
    original.dma();
    try std.testing.expect(original.data_lost);
    for ([_]bool{ false, true }) |enabled| {
        var fixed: Model = .{ .interrupts = enabled, .delayed = true };
        start(&fixed, true);
        try std.testing.expect(fixed.armed and !fixed.data_lost);
        try std.testing.expectEqual(enabled, fixed.interrupts);
    }
    var no_data: Model = .{};
    start(&no_data, false);
    try std.testing.expect(!no_data.armed and no_data.interrupts);
}
