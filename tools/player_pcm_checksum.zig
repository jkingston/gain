//! Stable byte-order-independent FNV-1a digest for qualification PCM captures.
pub const initial: u32 = 2166136261;
pub fn update(previous: u32, frames: anytype) u32 {
    var hash = previous;
    for (frames) |frame| for ([_]i32{ frame.left, frame.right }) |sample| {
        const bits: u32 = @bitCast(sample);
        inline for (0..4) |byte| hash = (hash ^ @as(u8, @truncate(bits >> (byte * 8)))) *% 16777619;
    };
    return hash;
}
test "PCM digest preserves chunk boundaries, sign and channel order" {
    const std = @import("std");
    const Frame = struct { left: i32, right: i32 };
    const frames = [_]Frame{ .{ .left = -1, .right = 0 }, .{ .left = 7, .right = -9 } };
    try std.testing.expectEqual(update(initial, &frames), update(update(initial, frames[0..1]), frames[1..]));
    try std.testing.expect(update(initial, &frames) != update(initial, &[_]Frame{ .{ .left = 0, .right = -1 }, frames[1] }));
    try std.testing.expectEqual(initial, update(initial, frames[0..0]));
}
