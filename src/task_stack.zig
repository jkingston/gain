//! Stack admission and optional high-water measurement, outside audio hot loops.
const std = @import("std");
pub const guard_bytes = 64;
const paint: u8 = 0xa5;
pub fn prepare(bytes: []u8, measure: bool) void {
    std.debug.assert(bytes.len >= guard_bytes);
    @memset(if (measure) bytes else bytes[0..guard_bytes], paint);
}
pub fn intact(bytes: []const u8) bool {
    if (bytes.len < guard_bytes) return false;
    for (bytes[0..guard_bytes]) |value| if (value != paint) return false;
    return true;
}
pub fn used(bytes: []const u8) usize {
    for (bytes, 0..) |value, offset| if (value != paint) return bytes.len - offset;
    return 0;
}
pub const Bounds = struct {
    bottom: u32 = 0,
    top: u32 = 0,
    pub fn contains(self: Bounds, pointer: u32) bool {
        return self.bottom == 0 or (pointer >= self.bottom and pointer <= self.top and pointer & 7 == 0);
    }
};
test "stack fence and high-water detect damage without scanning outside the reservation" {
    var bytes: [1024]u8 = undefined;
    prepare(&bytes, true);
    try std.testing.expect(intact(&bytes));
    try std.testing.expectEqual(@as(usize, 0), used(&bytes));
    bytes[900] = 0;
    try std.testing.expectEqual(@as(usize, 124), used(&bytes));
    try std.testing.expect(intact(&bytes));
    bytes[guard_bytes - 1] = 0;
    try std.testing.expect(!intact(&bytes));
    try std.testing.expect(!intact(bytes[0 .. guard_bytes - 1]));
}
test "stack pointer bounds include O32 alignment and reject both neighbouring stacks" {
    const bounds = Bounds{ .bottom = 0x1000, .top = 0x2000 };
    for ([_]u32{ 0x1000, 0x1008, 0x1ff0, 0x2000 }) |pointer| try std.testing.expect(bounds.contains(pointer));
    for ([_]u32{ 0xff8, 0x1001, 0x1004, 0x2008 }) |pointer| try std.testing.expect(!bounds.contains(pointer));
    try std.testing.expect((Bounds{}).contains(0));
}
