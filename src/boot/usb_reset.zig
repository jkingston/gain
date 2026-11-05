//! Bounded DWC2 DMA-to-ROM reset. The address mapping may be released only
//! after the AHB master is idle and the core has completed its reset.
pub const ahb_idle: u32 = 1 << 31;
pub const soft_reset: u32 = 1;

pub fn reset(driver: anytype, timeout_ticks: u32) !void {
    const began = driver.now();
    while (driver.state() & ahb_idle == 0) {
        if (driver.now() -% began >= timeout_ticks) return error.UsbDmaBusy;
    }
    driver.requestReset();
    while (true) {
        const state = driver.state();
        if (state & soft_reset == 0 and state & ahb_idle != 0) break;
        if (driver.now() -% began >= timeout_ticks) return error.UsbResetTimeout;
    }
    driver.settle();
}

const Fake = struct {
    states: []const u32,
    position: usize = 0,
    ticks: u32 = 0,
    requests: usize = 0,
    settled: bool = false,

    fn now(self: *@This()) u32 {
        const old = self.ticks;
        self.ticks +%= 1;
        return old;
    }

    fn state(self: *@This()) u32 {
        const value = self.states[@min(self.position, self.states.len - 1)];
        self.position += 1;
        return value;
    }

    fn requestReset(self: *@This()) void {
        self.requests += 1;
    }

    fn settle(self: *@This()) void {
        self.settled = true;
    }
};

test "reset waits for idle on both sides and handles timer rollover" {
    const std = @import("std");
    for ([_]u32{ 0, 0xfffffffc }) |start| {
        var driver: Fake = .{ .states = &.{ 0, 0, ahb_idle, soft_reset, 0, ahb_idle }, .ticks = start };
        try reset(&driver, 20);
        try std.testing.expectEqual(1, driver.requests);
        try std.testing.expect(driver.settled);
        try std.testing.expectEqual(6, driver.position);
    }
}

test "busy or stuck cores time out without permitting mapping release" {
    const std = @import("std");

    var busy: Fake = .{ .states = &.{0} };
    try std.testing.expectError(error.UsbDmaBusy, reset(&busy, 10));
    try std.testing.expectEqual(0, busy.requests);
    try std.testing.expect(!busy.settled);
    var stuck: Fake = .{ .states = &.{ ahb_idle, soft_reset } };
    try std.testing.expectError(error.UsbResetTimeout, reset(&stuck, 10));
    try std.testing.expectEqual(1, stuck.requests);
    try std.testing.expect(!stuck.settled);
    var not_idle: Fake = .{ .states = &.{ ahb_idle, 0 } };
    try std.testing.expectError(error.UsbResetTimeout, reset(&not_idle, 10));
    try std.testing.expect(!not_idle.settled);
}
