//! Acknowledge the vendor boot-attempt marker without changing recovery requests.
const std = @import("std");
pub const watchdog_signature: u16 = 0xa1a1;

pub fn acknowledge(io: anytype) !void {
    const before = io.read();
    if (@as(u16, @truncate(before)) != watchdog_signature) return;
    io.unlock();
    defer io.lock();
    io.settle();
    const expected = before & 0xffff0000;
    io.write(expected);
    if (io.read() != expected) return error.BootAcknowledgementFailed;
}

test "acknowledgement preserves upper flags and leaves other boot requests untouched" {
    const Mock = struct {
        value: u32,
        unlocked: bool = false,
        writes: u32 = 0,
        reject: bool = false,
        fn read(self: *@This()) u32 {
            return self.value;
        }
        fn unlock(self: *@This()) void {
            self.unlocked = true;
        }
        fn lock(self: *@This()) void {
            self.unlocked = false;
        }
        fn settle(_: *@This()) void {}
        fn write(self: *@This(), value: u32) void {
            std.debug.assert(self.unlocked);
            self.writes += 1;
            if (!self.reject) self.value = value;
        }
    };
    for ([_]u32{ 0x1357a1a1, 0x0000a1a1, 0x13571a1a, 0x13570000, 0xffffffff }) |initial| {
        var io = Mock{ .value = initial };
        try acknowledge(&io);
        const marked = @as(u16, @truncate(initial)) == watchdog_signature;
        try std.testing.expectEqual(if (marked) initial & 0xffff0000 else initial, io.value);
        try std.testing.expectEqual(@as(u32, @intFromBool(marked)), io.writes);
        try std.testing.expect(!io.unlocked);
        try acknowledge(&io);
        try std.testing.expectEqual(@as(u32, @intFromBool(marked)), io.writes);
    }
    var rejected = Mock{ .value = 0x1357a1a1, .reject = true };
    try std.testing.expectError(error.BootAcknowledgementFailed, acknowledge(&rejected));
    try std.testing.expect(!rejected.unlocked);
}
